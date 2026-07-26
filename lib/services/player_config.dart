import 'dart:io';

import 'package:dio/dio.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import 'network.dart';

/// Apply the mpv settings a source's stream needs before opening it.
///
/// Shared by the player page and the verification test so what we test is
/// literally what we ship.
Future<void> configurePlayerFor(
  Player player,
  String package,
  AnimeWatch watch,
) async {
  final platform = player.platform;
  if (platform is! NativePlayer) return;

  // libmpv reads http_proxy from the environment on its own; Chinese CDNs
  // reject foreign proxy exits, so the route must be stated explicitly.
  final useProxy = Network.usesProxyFor(package, override: watch.netMode);
  final proxy = Network.resolvedProxy();
  await platform.setProperty(
      'http-proxy', useProxy && proxy.isNotEmpty ? 'http://$proxy' : '');

  await platform.setProperty(
      'user-agent', watch.headers['User-Agent'] ?? kDefaultUserAgent);

  final referer = watch.headers['Referer'] ?? watch.headers['referer'];
  if (referer != null && referer.isNotEmpty) {
    await platform.setProperty('referrer', referer);
  }

  // An inlined playlist counts as a location change when it points at http
  // segments, which mpv refuses unless told otherwise.
  await platform.setProperty('load-unsafe-playlists', 'yes');
}

/// Build the [Media] to hand the player.
///
/// HLS gets special treatment: mpv parses .m3u8 with its own playlist reader,
/// which resolves root-relative entries such as "/a/b.ts" as local file paths
/// and fails outright. Rather than fight its probing order, fetch the playlist
/// over the source's own route, rewrite every reference to an absolute URL,
/// and inline the result — leaving mpv nothing to resolve.
Future<Media> buildMedia(String package, AnimeWatch watch) async {
  final headers = watch.headers.isEmpty ? null : watch.headers;
  final isHls = watch.type == 'hls' || watch.url.contains('.m3u8');
  // A downloaded episode is already a local playlist with its segments beside
  // it, so there is nothing to fetch or rewrite.
  final isLocal = !watch.url.startsWith('http');
  if (!isHls || isLocal) return Media(watch.url, httpHeaders: headers);

  try {
    final dio = watch.netMode == null
        ? Network.forPackage(package)
        : (watch.netMode == 'direct' ? Network.direct : Network.proxied);

    Future<String> fetch(String url) async {
      final response = await dio.get<String>(
        url,
        options: Options(
          headers: watch.headers,
          responseType: ResponseType.plain,
        ),
      );
      return response.data ?? '';
    }

    var playlistUrl = watch.url;
    var body = await fetch(playlistUrl);
    if (!body.contains('#EXTM3U')) return Media(watch.url, httpHeaders: headers);

    // A master playlist only lists variants; step into the best one.
    if (body.contains('#EXT-X-STREAM-INF')) {
      final variant = _bestVariant(playlistUrl, body);
      if (variant != null) {
        playlistUrl = variant;
        body = await fetch(playlistUrl);
      }
    }

    // Inlining via memory:// does not survive the newlines, so stage the
    // rewritten playlist on disk instead.
    final dir = await getTemporaryDirectory();
    final name = 'fusion_${playlistUrl.hashCode.toRadixString(16)}.m3u8';
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsString(_absolutise(playlistUrl, body));
    return Media(file.path, httpHeaders: headers);
  } catch (_) {
    // If anything about the rewrite fails, let mpv try the url as-is.
    return Media(watch.url, httpHeaders: headers);
  }
}

String? _bestVariant(String base, String body) {
  final lines = body.split(RegExp(r'\r?\n'));
  String? best;
  var bestBandwidth = -1;
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue;
    final match = RegExp(r'BANDWIDTH=(\d+)').firstMatch(lines[i]);
    final bandwidth = match == null ? 0 : int.parse(match.group(1)!);
    for (var j = i + 1; j < lines.length; j++) {
      final candidate = lines[j].trim();
      if (candidate.isEmpty || candidate.startsWith('#')) continue;
      if (bandwidth > bestBandwidth) {
        bestBandwidth = bandwidth;
        best = _resolve(base, candidate);
      }
      break;
    }
  }
  return best;
}

/// Rewrite segment URIs and any URI="..." attributes to absolute urls.
String _absolutise(String base, String body) {
  final out = StringBuffer();
  for (final rawLine in body.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#')) {
      // Tags such as #EXT-X-KEY and #EXT-X-MAP carry their own URI attribute.
      out.writeln(line.replaceAllMapped(
        RegExp(r'URI="([^"]+)"'),
        (m) => 'URI="${_resolve(base, m.group(1)!)}"',
      ));
    } else {
      out.writeln(_resolve(base, line));
    }
  }
  return out.toString();
}

String _resolve(String base, String ref) {
  if (ref.startsWith('http://') || ref.startsWith('https://')) return ref;
  try {
    return Uri.parse(base).resolve(ref).toString();
  } catch (_) {
    return ref;
  }
}
