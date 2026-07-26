// Verifies that caching stores real bytes and that a cached episode still
// opens when the network is gone.
//
// The point of the cache is offline reading, so it is checked by pointing the
// app at an unreachable proxy after downloading: anything that silently falls
// back to the network fails here.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/services/extension_manager.dart';
import 'package:fusion_reader/services/network.dart';
import 'package:fusion_reader/services/offline_cache.dart';
import 'package:fusion_reader/services/sources.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('cached episodes survive losing the network', (tester) async {
    await tester.runAsync(() async {
      await Storage.init();
      await ExtensionManager.instance.init();
      await OfflineCache.clearAll();

      final report = StringBuffer('\n===== OFFLINE CACHE REPORT =====\n');

      // A comic and a novel, so both the image and the text path are covered.
      final targets = <MediaType, String>{
        MediaType.manga: 'weebcentral',
        MediaType.novel: 'gutenberg',
      };

      final cached = <MediaType, (MediaItem, MediaEpisode)>{};

      for (final entry in targets.entries) {
        final service = ExtensionManager.instance.byPackage(entry.value);
        if (service == null) continue;

        final results = await service.search(
            entry.key == MediaType.manga ? 'naruto' : 'sherlock', 1);
        expect(results, isNotEmpty, reason: '${entry.value} 搜索为空');
        final item = results.first;
        final detail = await service.detail(item.url);
        final episode = detail.episodes.first.urls.first;

        await OfflineCache.instance.download(item, episode);
        expect(OfflineCache.has(item.package, episode.url), isTrue,
            reason: '${entry.value} 下载后没有留下清单');

        final manifest = OfflineCache.manifest(item.package, episode.url)!;
        final bytes = (manifest['bytes'] as num).toInt();
        report.writeln('[${entry.key.label}] ${entry.value} · ${episode.name}'
            ' -> ${(bytes / 1024).toStringAsFixed(0)} KB');
        expect(bytes, greaterThan(2000), reason: '${entry.value} 缓存内容过小');

        cached[entry.key] = (item, episode);
      }

      expect(cached.length, 2, reason: '两类内容都要缓存成功');

      // Now cut the network: every request is sent to a dead proxy.
      await Storage.setProxy('127.0.0.1:9');
      Network.reload();
      report.writeln('--- 已切断网络（代理指向无效端口 127.0.0.1:9）---');

      // Sanity check that the cut actually bites, otherwise the offline
      // assertions below would pass for the wrong reason.
      var networkIsDown = false;
      try {
        await ExtensionManager.instance.byPackage('gutenberg')!.latest(1);
      } catch (_) {
        networkIsDown = true;
      }
      expect(networkIsDown, isTrue, reason: '断网没有生效，后续断言不可信');
      report.writeln('    确认联网请求已失败');

      try {
        for (final entry in cached.entries) {
          final (item, episode) = entry.value;
          final raw = await Sources.watchCached(item, episode.url);

          if (entry.key == MediaType.manga) {
            final watch = MangaWatch.fromJson(raw);
            expect(watch.urls, isNotEmpty);
            final first = File(watch.urls.first);
            expect(first.existsSync(), isTrue,
                reason: '缓存的页面文件不存在: ${watch.urls.first}');
            expect(first.lengthSync(), greaterThan(1000),
                reason: '缓存的页面是空文件');
            report.writeln('[漫画] 离线读到 ${watch.urls.length} 页，'
                '首页 ${(first.lengthSync() / 1024).toStringAsFixed(0)} KB');
          } else {
            final watch = NovelWatch.fromJson(raw);
            final chars = watch.textLines.join().length;
            expect(chars, greaterThan(500), reason: '缓存的正文太短');
            report.writeln('[小说] 离线读到 $chars 字');
          }
        }

        // Removing a cache entry must also remove its files.
        final (item, episode) = cached[MediaType.manga]!;
        final pages =
            MangaWatch.fromJson(OfflineCache.read(item.package, episode.url)!);
        await OfflineCache.remove(item.package, episode.url);
        expect(OfflineCache.has(item.package, episode.url), isFalse);
        expect(File(pages.urls.first).existsSync(), isFalse,
            reason: '删除缓存后文件仍留在磁盘上');
        report.writeln('--- 删除缓存后文件已清理 ---');
      } finally {
        // Always restore the network, even if an expectation blew up.
        await Storage.setProxy('');
        Network.reload();
      }

      report.writeln('================================');
      print(report.toString());
      await OfflineCache.clearAll();
    });
  }, timeout: const Timeout(Duration(minutes: 12)));
}
