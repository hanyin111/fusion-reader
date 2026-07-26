import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import 'network.dart';
import 'sources.dart';

/// Progress of one in-flight download.
class DownloadProgress {
  final int done;
  final int total;
  final String label;
  const DownloadProgress(this.done, this.total, this.label);

  double get fraction => total == 0 ? 0 : done / total;
}

/// Stores episodes on disk so they can be re-read without the network.
///
/// Page urls from several sources are short-lived (MangaDex signs its image
/// hosts, video CDNs expire links), so caching the *addresses* would rot within
/// the hour. Everything here therefore stores the actual bytes.
class OfflineCache extends ChangeNotifier {
  OfflineCache._();
  static final OfflineCache instance = OfflineCache._();

  static late Directory _root;
  static late Box _manifests;
  static bool _ready = false;

  final Map<String, DownloadProgress> _active = {};
  final Map<String, CancelToken> _cancels = {};

  DownloadProgress? progressOf(String key) => _active[key];
  bool isDownloading(String key) => _active.containsKey(key);

  static String keyOf(String package, String episodeUrl) =>
      '$package|$episodeUrl';

  static Future<void> init(Box manifests) async {
    if (_ready) return;
    _manifests = manifests;
    final base = await getApplicationSupportDirectory();
    _root = Directory('${base.path}${Platform.pathSeparator}offline');
    if (!_root.existsSync()) _root.createSync(recursive: true);
    _ready = true;
  }

  // ---------- queries ----------

  static bool has(String package, String episodeUrl) =>
      _manifests.containsKey(keyOf(package, episodeUrl));

  static Map? manifest(String package, String episodeUrl) {
    final value = _manifests.get(keyOf(package, episodeUrl));
    return value is Map ? value : null;
  }

  /// Cached payload in the same shape `watch()` returns, or null when absent.
  static Map? read(String package, String episodeUrl) {
    final entry = manifest(package, episodeUrl);
    if (entry == null) return null;

    // A manifest whose files were removed underneath us is worse than no cache.
    final probe = entry['probe']?.toString();
    if (probe != null && probe.isNotEmpty && !File(probe).existsSync()) {
      return null;
    }
    final payload = entry['payload'];
    return payload is Map ? payload : null;
  }

  static List<Map> allEntries() =>
      _manifests.values.whereType<Map>().toList(growable: false);

  static Future<int> totalBytes() async {
    var total = 0;
    for (final entry in allEntries()) {
      total += (entry['bytes'] as num?)?.toInt() ?? 0;
    }
    return total;
  }

  // ---------- download ----------

  Future<void> cancel(String key) async {
    _cancels[key]?.cancel('用户取消');
  }

  Future<void> download(MediaItem item, MediaEpisode episode) async {
    final key = keyOf(item.package, episode.url);
    if (_active.containsKey(key) || has(item.package, episode.url)) return;

    final cancelToken = CancelToken();
    _cancels[key] = cancelToken;
    _active[key] = const DownloadProgress(0, 1, '准备中');
    notifyListeners();

    final dir = Directory(
        '${_root.path}${Platform.pathSeparator}${key.hashCode.toRadixString(16)}');
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final raw = await Sources.watch(item, episode.url);

      late Map payload;
      var bytes = 0;
      switch (item.type) {
        case MediaType.manga:
          (payload, bytes) =
              await _downloadManga(item, raw, dir, key, cancelToken);
        case MediaType.novel:
          (payload, bytes) =
              await _downloadNovel(item, raw, dir, key, cancelToken);
        case MediaType.anime:
          (payload, bytes) =
              await _downloadAnime(item, raw, dir, key, cancelToken);
      }

      await _manifests.put(key, {
        'key': key,
        'package': item.package,
        'itemKey': item.key,
        'itemTitle': item.title,
        'itemUrl': item.url,
        'itemCover': item.cover,
        'type': item.type.name,
        'episodeUrl': episode.url,
        'episodeName': episode.name,
        'payload': payload,
        'bytes': bytes,
        'probe': payload['__probe'] ?? '',
        'savedAt': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      // Never leave a half-written chapter that would read as complete.
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } catch (_) {}
      if (!cancelToken.isCancelled) rethrow;
    } finally {
      _active.remove(key);
      _cancels.remove(key);
      notifyListeners();
    }
  }

  Future<(Map, int)> _downloadManga(MediaItem item, Map raw, Directory dir,
      String key, CancelToken cancelToken) async {
    final watch = MangaWatch.fromJson(raw);
    if (watch.urls.isEmpty) throw Exception('该章节没有可下载的页面');

    final paths = <String>[];
    var bytes = 0;
    for (var i = 0; i < watch.urls.length; i++) {
      _active[key] = DownloadProgress(i, watch.urls.length, '第 ${i + 1} 页');
      notifyListeners();
      final target = '${dir.path}${Platform.pathSeparator}'
          '${i.toString().padLeft(4, '0')}${_extensionOf(watch.urls[i])}';
      bytes += await _fetchToFile(item.package, watch.urls[i], target,
          headers: watch.headers, netMode: watch.netMode, cancelToken: cancelToken);
      paths.add(target);
    }
    return ({'urls': paths, '__probe': paths.first}, bytes);
  }

  Future<(Map, int)> _downloadNovel(MediaItem item, Map raw, Directory dir,
      String key, CancelToken cancelToken) async {
    final watch = NovelWatch.fromJson(raw);
    final content = <dynamic>[];
    var bytes = 0;
    var imageIndex = 0;
    String? probe;

    for (final block in watch.blocks) {
      if (!block.isImage) {
        content.add(block.text);
        bytes += block.text.length;
        continue;
      }
      _active[key] =
          DownloadProgress(imageIndex, watch.blocks.length, '插图 ${imageIndex + 1}');
      notifyListeners();
      final target = '${dir.path}${Platform.pathSeparator}'
          'img${imageIndex.toString().padLeft(3, '0')}${_extensionOf(block.imageUrl)}';
      try {
        bytes += await _fetchToFile(item.package, block.imageUrl, target,
            headers: watch.headers,
            netMode: watch.netMode,
            cancelToken: cancelToken);
        content.add({'type': 'image', 'url': target});
        probe ??= target;
        imageIndex++;
      } catch (e) {
        // A missing illustration should not cost us the chapter text.
        if (cancelToken.isCancelled) rethrow;
      }
    }
    if (content.isEmpty) throw Exception('该章节没有可缓存的内容');

    // Text-only chapters still need a probe file to prove the cache is intact.
    probe ??= '${dir.path}${Platform.pathSeparator}text.json';
    if (!File(probe).existsSync()) {
      File(probe).writeAsStringSync(jsonEncode(content));
    }
    return (
      {'content': content, 'subtitle': watch.subtitle, '__probe': probe},
      bytes
    );
  }

  Future<(Map, int)> _downloadAnime(MediaItem item, Map raw, Directory dir,
      String key, CancelToken cancelToken) async {
    final watch = AnimeWatch.fromJson(raw);
    if (watch.url.isEmpty) throw Exception('没有取到播放地址');

    final isHls = watch.type == 'hls' || watch.url.contains('.m3u8');
    if (!isHls) {
      final target = '${dir.path}${Platform.pathSeparator}video.mp4';
      final bytes = await _fetchToFile(item.package, watch.url, target,
          headers: watch.headers,
          netMode: watch.netMode,
          cancelToken: cancelToken,
          onBytes: (received, total) {
            _active[key] = DownloadProgress(
                received ~/ 1024, (total <= 0 ? received : total) ~/ 1024, '视频');
            notifyListeners();
          });
      return ({'type': 'mp4', 'url': target, '__probe': target}, bytes);
    }

    // HLS: pull every segment and rewrite the playlist to point at them.
    final dio = _dioFor(item.package, watch.netMode);
    final playlistUrl = watch.url;
    final body = (await dio.get<String>(playlistUrl,
            options: Options(headers: watch.headers, responseType: ResponseType.plain),
            cancelToken: cancelToken))
        .data ??
        '';
    final lines = body.split(RegExp(r'\r?\n'));
    final segments = lines
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .toList();
    if (segments.isEmpty) throw Exception('播放列表里没有分片');

    final rewritten = <String>[];
    var bytes = 0;
    var index = 0;
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('#')) {
        // Encryption keys are fetched separately and must be localised too.
        final keyMatch = RegExp(r'URI="([^"]+)"').firstMatch(trimmed);
        if (keyMatch != null) {
          final keyTarget = '${dir.path}${Platform.pathSeparator}key$index.bin';
          bytes += await _fetchToFile(item.package,
              _resolve(playlistUrl, keyMatch.group(1)!), keyTarget,
              headers: watch.headers,
              netMode: watch.netMode,
              cancelToken: cancelToken);
          rewritten.add(trimmed.replaceFirst(
              keyMatch.group(0)!, 'URI="key$index.bin"'));
          continue;
        }
        rewritten.add(trimmed);
        continue;
      }
      _active[key] = DownloadProgress(index, segments.length, '分片 ${index + 1}');
      notifyListeners();
      final name = 'seg${index.toString().padLeft(5, '0')}.ts';
      bytes += await _fetchToFile(
          item.package, _resolve(playlistUrl, trimmed),
          '${dir.path}${Platform.pathSeparator}$name',
          headers: watch.headers, netMode: watch.netMode, cancelToken: cancelToken);
      // Relative names resolve against the playlist's own folder.
      rewritten.add(name);
      index++;
    }

    final localPlaylist = '${dir.path}${Platform.pathSeparator}index.m3u8';
    File(localPlaylist).writeAsStringSync(rewritten.join('\n'));
    return (
      {'type': 'hls', 'url': localPlaylist, '__probe': localPlaylist},
      bytes
    );
  }

  // ---------- removal ----------

  static Future<void> remove(String package, String episodeUrl) async {
    final key = keyOf(package, episodeUrl);
    final dir = Directory(
        '${_root.path}${Platform.pathSeparator}${key.hashCode.toRadixString(16)}');
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
    await _manifests.delete(key);
    instance.notifyListeners();
  }

  static Future<void> clearAll() async {
    try {
      if (_root.existsSync()) _root.deleteSync(recursive: true);
      _root.createSync(recursive: true);
    } catch (_) {}
    await _manifests.clear();
    instance.notifyListeners();
  }

  // ---------- helpers ----------

  static Dio _dioFor(String package, String? netMode) => netMode == null
      ? Network.forPackage(package)
      : (netMode == 'direct' ? Network.direct : Network.proxied);

  static String _resolve(String base, String ref) {
    if (ref.startsWith('http://') || ref.startsWith('https://')) return ref;
    try {
      return Uri.parse(base).resolve(ref).toString();
    } catch (_) {
      return ref;
    }
  }

  static String _extensionOf(String url) {
    final clean = url.split('?').first;
    final dot = clean.lastIndexOf('.');
    if (dot < 0 || clean.length - dot > 6) return '.img';
    return clean.substring(dot);
  }

  Future<int> _fetchToFile(
    String package,
    String url,
    String target, {
    Map<String, String> headers = const {},
    String? netMode,
    CancelToken? cancelToken,
    void Function(int received, int total)? onBytes,
  }) async {
    // Locally imported media is already on disk; just copy it across.
    if (!url.startsWith('http')) {
      final source = File(url);
      if (!source.existsSync()) throw Exception('本地文件不存在: $url');
      source.copySync(target);
      return source.lengthSync();
    }
    final response = await _dioFor(package, netMode).get<List<int>>(
      url,
      options: Options(
        responseType: ResponseType.bytes,
        headers: headers.isEmpty ? null : headers,
      ),
      cancelToken: cancelToken,
      onReceiveProgress: onBytes,
    );
    final data = response.data ?? const <int>[];
    File(target).writeAsBytesSync(data);
    return data.length;
  }
}
