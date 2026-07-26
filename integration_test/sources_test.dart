// Live end-to-end verification of every bundled extension source.
// Run with:  flutter test integration_test/sources_test.dart -d windows
// ignore_for_file: avoid_print
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/services/extension_manager.dart';
import 'package:fusion_reader/services/image_loader.dart';
import 'package:fusion_reader/services/network.dart';
import 'package:fusion_reader/services/player_config.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

const searchKeywords = {
  'mangadex': 'one piece',
  'weebcentral': 'naruto',
  'picacg': '全彩',
  'gutenberg': 'sherlock',
  'royalroad': 'mother of learning',
  'esjzone': '魔法',
  'linovelib': '魔法',
  'yhdm': '进击',
  'archiveanime': 'popeye',
};

/// Actually play the stream for a few seconds — a resolvable url is not the
/// same as a playable one, which is exactly how the proxy bug slipped through.
Future<String> verifyPlayback(String package, AnimeWatch watch) async {
  final player = Player();
  try {
    await configurePlayerFor(player, package, watch);

    final completer = Completer<String>();
    final subs = <StreamSubscription>[];
    final logLines = <String>[];
    subs.add(player.stream.log.listen((l) {
      if (l.level == 'error' || l.level == 'fatal') {
        logLines.add('${l.prefix}: ${l.text}');
      }
    }));
    subs.add(player.stream.error.listen((e) {
      // media_kit emits an empty error event during open; only a non-empty
      // message means the load actually failed.
      if (e.trim().isEmpty) return;
      if (!completer.isCompleted) completer.complete('MPV-ERROR: $e');
    }));
    // Position advancing past zero means bytes are actually decoding.
    subs.add(player.stream.position.listen((p) {
      if (p.inMilliseconds > 0 && !completer.isCompleted) {
        completer.complete('PLAYING at ${p.inMilliseconds}ms');
      }
    }));

    await player.open(await buildMedia(package, watch));
    await player.play();

    final result = await completer.future.timeout(
      const Duration(seconds: 45),
      onTimeout: () => 'TIMEOUT: 45s 内没有解码出任何画面'
          '${logLines.isEmpty ? "" : "\nmpv日志: ${logLines.take(6).join(" | ")}"}',
    );
    for (final s in subs) {
      await s.cancel();
    }
    return result;
  } finally {
    await player.dispose();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  testWidgets('verify all bundled sources end-to-end', (tester) async {
    await tester.runAsync(() async {
      await Storage.init();
      final manager = ExtensionManager.instance;
      await manager.init();

      final report = StringBuffer('\n===== SOURCE VERIFICATION REPORT =====\n');
      report.writeln('全局代理: ${Network.resolvedProxy().isEmpty ? "无" : Network.resolvedProxy()}');
      final workingByType = <MediaType, int>{};
      final failures = <String>[];

      for (final err in manager.loadErrors.entries) {
        report.writeln('[LOAD-FAIL] ${err.key}: ${err.value}');
        failures.add('${err.key} (load): ${err.value}');
      }

      for (final service in manager.enabled) {
        final pkg = service.meta.package;
        final type = service.meta.type;
        final route = Network.modeFor(pkg).label +
            (Network.usesProxyFor(pkg) ? '(经代理)' : '(直连)');
        print('>>> testing $pkg [$route] ...');
        try {
          print('    latest...');
          final latest = await service.latest(1);
          if (latest.isEmpty) throw Exception('latest() 返回空列表');

          final kw = searchKeywords[pkg] ?? latest.first.title.split(' ').first;
          print('    search("$kw")...');
          final searchResults = await service.search(kw, 1);
          if (searchResults.isEmpty) throw Exception('search("$kw") 返回空列表');

          final item = searchResults.first;
          print('    detail("${item.title}")...');
          final detail = await service.detail(item.url);
          if (detail.episodes.isEmpty || detail.episodes.first.urls.isEmpty) {
            throw Exception('detail("${item.url}") 没有返回任何章节');
          }
          final totalEps =
              detail.episodes.fold<int>(0, (s, g) => s + g.urls.length);

          // Cover art travels the same route as the extension; check it loads.
          String coverStatus = '无封面';
          if (item.cover.isNotEmpty) {
            try {
              final bytes = await SourceImageCache.fetchBytes(pkg, item.cover);
              coverStatus = bytes.length > 500
                  ? '封面OK ${(bytes.length / 1024).toStringAsFixed(0)}KB'
                  : '封面异常(${bytes.length}B)';
            } catch (e) {
              coverStatus = '封面失败: $e';
            }
          }

          final ep = detail.episodes.first.urls.first;
          print('    watch("${ep.name}")...');
          final watch = await service.watch(ep.url);
          String watchSummary;
          switch (type) {
            case MediaType.manga:
              final w = MangaWatch.fromJson(watch);
              if (w.urls.isEmpty) throw Exception('watch() 没有返回任何页面');
              // Verify a page image really downloads through this route.
              final bytes = await SourceImageCache.fetchBytes(pkg, w.urls.first,
                  headers: w.headers.isEmpty ? null : w.headers,
                  netMode: w.netMode);
              if (bytes.length < 1000) {
                throw Exception('首页图片下载异常，仅 ${bytes.length} 字节');
              }
              watchSummary =
                  '${w.urls.length} 页，首页实测下载 ${(bytes.length / 1024).toStringAsFixed(0)}KB';
            case MediaType.novel:
              final w = NovelWatch.fromJson(watch);
              final chars = w.textLines.join().length;
              if (chars < 100) throw Exception('watch() 正文不足 100 字');
              final images = w.blocks.where((b) => b.isImage).toList();
              var imageNote = '无插图';
              if (images.isNotEmpty) {
                // Artwork must load through the same route/headers as the text.
                final bytes = await SourceImageCache.fetchBytes(
                    pkg, images.first.imageUrl,
                    headers: w.headers.isEmpty ? null : w.headers,
                    netMode: w.netMode);
                imageNote = bytes.length > 1000
                    ? '${images.length} 张插图，首张实测下载 ${(bytes.length / 1024).toStringAsFixed(0)}KB'
                    : '插图下载异常(${bytes.length}B)';
              }
              watchSummary = '$chars 字，$imageNote';
            case MediaType.anime:
              final w = AnimeWatch.fromJson(watch);
              if (w.url.isEmpty) throw Exception('watch() 返回空播放地址');
              print('    verifying playback: ${w.url}');
              final playback = await verifyPlayback(pkg, w);
              if (!playback.startsWith('PLAYING')) {
                throw Exception('拿到地址但无法播放 -> $playback\n地址: ${w.url}');
              }
              watchSummary = '[${w.type}] $playback';
          }

          workingByType[type] = (workingByType[type] ?? 0) + 1;
          report
            ..writeln('[OK] $pkg (${type.name}) 路由=$route')
            ..writeln('     latest: ${latest.length} 条, 例: "${latest.first.title}"')
            ..writeln('     search("$kw"): ${searchResults.length} 条')
            ..writeln('     detail("${detail.title}"): 共 $totalEps 话 / '
                '${detail.episodes.map((g) => '${g.title}:${g.urls.length}').join(', ')}')
            ..writeln('     $coverStatus')
            ..writeln('     watch("${ep.name}"): $watchSummary');
        } catch (e) {
          final short = e.toString().split('\n').take(4).join('\n       ');
          report.writeln('[FAIL] $pkg (${type.name}) 路由=$route: $short');
          failures.add('$pkg: $short');
        }
      }

      report.writeln('---------------------------------------');
      for (final t in MediaType.values) {
        report.writeln('${t.label}: ${workingByType[t] ?? 0} 个可用源');
      }
      report.writeln('=======================================');
      print(report.toString());

      for (final t in MediaType.values) {
        expect(workingByType[t] ?? 0, greaterThanOrEqualTo(2),
            reason: '${t.label} 类目可用源不足 2 个。失败详情:\n${failures.join('\n')}');
      }
    });
  }, timeout: const Timeout(Duration(minutes: 25)));
}
