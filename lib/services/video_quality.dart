import 'package:dio/dio.dart';

import '../models/models.dart';
import 'network.dart';

bool isHlsVideo(AnimeWatch watch) =>
    watch.type == 'hls' || watch.url.toLowerCase().contains('.m3u8');

class VideoQuality {
  final String label;
  final AnimeWatch watch;
  final HlsMaster? master;
  final HlsVariant? variant;
  final String? playlistBody;

  const VideoQuality({
    required this.label,
    required this.watch,
    this.master,
    this.variant,
    this.playlistBody,
  });
}

class HlsVariant {
  final String url;
  final String tag;
  final Map<String, String> attributes;

  const HlsVariant(this.url, this.tag, this.attributes);

  int get bandwidth => int.tryParse(attributes['BANDWIDTH'] ?? '') ?? 0;
  int get height =>
      int.tryParse((attributes['RESOLUTION'] ?? '').split('x').last) ?? 0;
  String get bitrateLabel => bandwidth >= 1000000
      ? '${(bandwidth / 1000000).toStringAsFixed(1)} Mbps'
      : '${(bandwidth / 1000).round()} kbps';
}

/// Parses quoted HLS attribute values without splitting CODECS or NAME commas.
Map<String, String> hlsAttributes(String tag) => {
  for (final match in RegExp(
    r'(?:^|,)([A-Z0-9-]+)=(?:"([^"]*)"|([^,]*))',
  ).allMatches(tag.substring(tag.indexOf(':') + 1)))
    match.group(1)!: match.group(2) ?? match.group(3)!,
};

String resolveHlsUri(String base, String reference) =>
    Uri.parse(base).resolve(reference).toString();

String absolutiseHls(String base, String body) => body
    .split(RegExp(r'\r?\n'))
    .map((line) => line.trim())
    .where((line) => line.isNotEmpty)
    .map(
      (line) => line.startsWith('#')
          ? line.replaceAllMapped(
              RegExp(r'URI="([^"]+)"'),
              (match) => 'URI="${resolveHlsUri(base, match.group(1)!)}"',
            )
          : resolveHlsUri(base, line),
    )
    .join('\n');

class HlsMaster {
  final String url;
  final String body;
  final List<HlsVariant> variants;

  const HlsMaster._(this.url, this.body, this.variants);

  factory HlsMaster.parse(String url, String body) {
    final variants = <HlsVariant>[];
    String? pending;
    for (final raw in body.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        pending = line;
      } else if (line.isNotEmpty && !line.startsWith('#') && pending != null) {
        final attributes = hlsAttributes(pending);
        final codecs = (attributes['CODECS'] ?? '').split(',');
        final audioOnly =
            !attributes.containsKey('RESOLUTION') &&
            codecs.isNotEmpty &&
            codecs.every(
              (codec) =>
                  RegExp(r'^(mp4a|ac-3|ec-3|opus|flac)').hasMatch(codec.trim()),
            );
        final resolved = resolveHlsUri(url, line);
        if (!audioOnly &&
            AnimeQuality.validUrl(resolved) &&
            !variants.any((variant) => variant.url == resolved)) {
          variants.add(HlsVariant(resolved, pending, attributes));
        }
        pending = null;
      }
    }
    variants.sort((a, b) {
      final byHeight = b.height.compareTo(a.height);
      return byHeight != 0 ? byHeight : b.bandwidth.compareTo(a.bandwidth);
    });
    return HlsMaster._(url, body, List.unmodifiable(variants));
  }

  String labelFor(HlsVariant variant) {
    if (variant.height > 0) {
      final sameHeight = variants.where((v) => v.height == variant.height);
      return sameHeight.length > 1
          ? '${variant.height}P · ${variant.bitrateLabel}'
          : '${variant.height}P';
    }
    return variant.attributes['NAME'] ??
        (variant.bandwidth > 0
            ? variant.bitrateLabel
            : '画质 ${variants.indexOf(variant) + 1}');
  }
}

/// Uses the final response URI, so relative variants survive CDN redirects.
Future<({String url, String body})> fetchVideoPlaylist(
  Dio client,
  AnimeWatch watch,
) async {
  final response = await client.get<String>(
    watch.url,
    options: Options(headers: watch.headers, responseType: ResponseType.plain),
  );
  final body = response.data ?? '';
  if (!body.trimLeft().startsWith('#EXTM3U')) {
    throw const FormatException('播放列表格式无效');
  }
  return (url: response.realUri.toString(), body: body);
}

/// No extra site API is required when the HLS master already lists qualities.
Future<List<VideoQuality>> resolveVideoQualities(
  String package,
  AnimeWatch watch, {
  Dio? client,
}) async {
  final options = <VideoQuality>[];
  if (isHlsVideo(watch) && AnimeQuality.validUrl(watch.url)) {
    try {
      final playlist = await fetchVideoPlaylist(
        client ?? Network.forPackage(package, override: watch.netMode),
        watch,
      );
      final master = HlsMaster.parse(playlist.url, playlist.body);
      if (master.variants.isNotEmpty) {
        for (final variant in master.variants) {
          options.add(
            VideoQuality(
              label: master.labelFor(variant),
              watch: watch.withQuality(
                AnimeQuality(label: '', url: variant.url, type: 'hls'),
              ),
              master: master,
              variant: variant,
            ),
          );
        }
      } else {
        options.add(
          VideoQuality(
            label: '原画',
            watch: watch.withQuality(
              AnimeQuality(label: '', url: playlist.url, type: 'hls'),
            ),
            playlistBody: playlist.body,
          ),
        );
      }
    } catch (_) {
      // Keep the existing URL usable even if quality discovery is unavailable.
    }
  }
  if (options.isEmpty && watch.url.isNotEmpty) {
    final matching = watch.qualities.where((entry) => entry.url == watch.url);
    options.add(
      VideoQuality(
        label: matching.isEmpty ? '原画' : matching.first.label,
        watch: matching.isEmpty ? watch : watch.withQuality(matching.first),
      ),
    );
  }
  for (final source in watch.qualities) {
    if (!options.any((option) => option.watch.url == source.url)) {
      options.add(
        VideoQuality(label: source.label, watch: watch.withQuality(source)),
      );
    }
  }
  return List.unmodifiable(options);
}
