import 'dart:io';

import 'package:dio/dio.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import 'network.dart';
import 'video_quality.dart';
import 'separate_media.dart';

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
  await Network.prepare();
  final uri = Uri.tryParse(watch.url);
  final useProxy = Network.usesProxyFor(
    package,
    override: watch.netMode,
    uri: uri,
  );
  final proxy = Network.resolvedProxy(uri: uri);
  await platform.setProperty(
    'http-proxy',
    useProxy && proxy.isNotEmpty ? 'http://$proxy' : '',
  );

  await platform.setProperty(
    'user-agent',
    watch.headers['User-Agent'] ?? kDefaultUserAgent,
  );

  final referer = watch.headers['Referer'] ?? watch.headers['referer'];
  await platform.setProperty('referrer', referer ?? '');
  // The native on-load lookup can miss headers for staged local playlists
  // (notably Windows \\?\ paths). Apply them explicitly after stopping the
  // previous media, whose unload hook clears this property.
  await platform.command(['change-list', 'http-header-fields', 'clr', '']);
  for (final entry in watch.headers.entries) {
    // append takes a single literal field: commas and backslashes in cookies
    // or other header values must not be parsed as list separators/escapes.
    await platform.command([
      'change-list',
      'http-header-fields',
      'append',
      '${entry.key}: ${entry.value}',
    ]);
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
Future<Media> buildMedia(
  String package,
  AnimeWatch watch, {
  VideoQuality? quality,
  Directory? playlistDirectory,
  Dio? client,
  bool fallback = true,
}) async {
  watch = quality?.watch ?? watch;
  final headers = watch.headers.isEmpty ? null : watch.headers;
  if (watch.audioUrl != null) {
    if (!AnimeQuality.validUrl(watch.url)) {
      throw const FormatException('视频地址格式不正确');
    }
    final directory = playlistDirectory ?? await getTemporaryDirectory();
    final path = directory.uri.resolve(
      'fusion_${DateTime.now().microsecondsSinceEpoch}_${_playlistSerial++}.edl',
    );
    final file = File.fromUri(path);
    await file.writeAsString(separateMediaPlaylist(watch.url, watch.audioUrl!));
    return Media(file.path, httpHeaders: headers);
  }
  // A downloaded episode is already a local playlist with its segments beside
  // it, so there is nothing to fetch or rewrite.
  final isLocal = !watch.url.startsWith('http');
  if (!isHlsVideo(watch) || isLocal) {
    return Media(watch.url, httpHeaders: headers);
  }

  try {
    final builder = _HlsMediaBuilder(
      client ?? Network.forPackage(package, override: watch.netMode),
      watch,
      playlistDirectory ?? await getTemporaryDirectory(),
    );
    final path = quality?.master != null
        ? await builder.master(quality!.master!, quality.variant!, 0)
        : await builder.stage(watch.url, body: quality?.playlistBody);
    return Media(path, httpHeaders: headers);
  } catch (_) {
    if (!fallback) rethrow;
    // If anything about the rewrite fails, let mpv try the url as-is.
    return Media(quality?.master?.url ?? watch.url, httpHeaders: headers);
  }
}

/// Opening a new encoding resets playback state in media_kit. Supply the
/// position at open time and restore speed for both playing and paused videos.
Future<void> replaceVideoMedia(
  Player player,
  Media media, {
  Future<void> Function()? configure,
}) async {
  final position = player.state.completed
      ? Duration.zero
      : player.state.position;
  final playing = player.state.playing;
  final rate = player.state.rate;
  if (configure != null) {
    await player.stop();
    await configure();
  }
  await player.open(
    Media(media.uri, httpHeaders: media.httpHeaders, start: position),
    play: playing,
  );
  await player.setRate(rate);
}

int _playlistSerial = 0;

class _HlsMediaBuilder {
  final Dio client;
  final AnimeWatch watch;
  final Directory directory;

  _HlsMediaBuilder(this.client, this.watch, this.directory);

  Future<String> write(String body) async {
    final name =
        'fusion_${DateTime.now().microsecondsSinceEpoch}_${_playlistSerial++}.m3u8';
    final file = File.fromUri(directory.uri.resolve(name));
    await file.writeAsString(body);
    return file.path;
  }

  Future<String> stage(String url, {String? body, int depth = 0}) async {
    if (depth > 4) throw const FormatException('播放列表嵌套过深');
    var base = url;
    if (body == null) {
      final document = await fetchVideoPlaylist(
        client,
        watch.withQuality(AnimeQuality(label: '', url: url, type: 'hls')),
      );
      base = document.url;
      body = document.body;
    }
    final parsed = HlsMaster.parse(base, body);
    if (parsed.variants.isNotEmpty) {
      return master(parsed, parsed.variants.first, depth);
    }
    if (body.contains('#EXT-X-STREAM-INF:')) {
      throw const FormatException('播放列表中没有可用的视频画质');
    }
    return write(absolutiseHls(base, body));
  }

  Future<String> master(
    HlsMaster playlist,
    HlsVariant variant,
    int depth,
  ) async {
    final video = await stage(variant.url, depth: depth + 1);
    final out = StringBuffer();
    var hasRenditions = false;
    for (final raw in playlist.body.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        continue;
      }
      if (line.isEmpty) continue;
      if (!line.startsWith('#')) {
        continue;
      }
      if (line.startsWith('#EXT-X-I-FRAME-STREAM-INF:')) continue;
      if (line.startsWith('#EXT-X-MEDIA:')) {
        final attributes = hlsAttributes(line);
        final type = attributes['TYPE'];
        final group = attributes['GROUP-ID'];
        if (group == null || variant.attributes[type] != group) continue;
        hasRenditions = true;
        final uri = attributes['URI'];
        if (uri != null) {
          final local = await stage(
            resolveHlsUri(playlist.url, uri),
            depth: depth + 1,
          );
          out.writeln(
            line.replaceFirst('URI="$uri"', 'URI="${_fileReference(local)}"'),
          );
        } else {
          out.writeln(line);
        }
      } else {
        out.writeln(absolutiseHls(playlist.url, line));
      }
    }
    // A video-only stream can open directly. Keep a one-variant master when
    // audio/subtitle renditions live outside the video playlist.
    if (!hasRenditions) return video;
    out.writeln(variant.tag);
    out.writeln(_fileReference(video));
    return write(out.toString());
  }

  // FFmpeg cannot resolve children against mpv's \\?\ Windows filename and
  // does not decode file:///C:/ URIs. A native absolute path works in both
  // readers and avoids changing spaces/non-ASCII characters into escapes.
  String _fileReference(String path) => path.replaceAll('\\', '/');
}
