import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/pages/cache_list_page.dart';
import 'package:fusion_reader/pages/detail_page.dart';
import 'package:fusion_reader/services/extension_manager.dart';
import 'package:fusion_reader/services/offline_cache.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'linovelib_test.dart' show isolateLinovelibTestStorage;

const item = MediaItem(
  package: 'cache_queue_fixture',
  type: MediaType.novel,
  title: '队列测试小说',
  url: '/work',
);
const script = '''
// ==MiruExtension==
// @name Cache queue test
// @version v1.0.0
// @package cache_queue_fixture
// @type fikushon
// @webSite https://example.invalid
// ==/MiruExtension==
export default class extends Extension {
  async detail() { return {title: '队列测试小说', episodes: [{title: '章节', urls: [
    {name: '第一章', url: '/1'}, {name: '第二章', url: '/2'}, {name: '第三章', url: '/3'}
  ]}]}; }
  async watch(url) { await this.sleep(1200); return {content: ['离开目录后保存的正文 ' + url]}; }
}
''';

void main() {
  isolateLinovelibTestStorage();
  testWidgets(
    'cache batch survives leaving the real detail page and is managed in the cache list',
    (tester) async {
      await tester.runAsync(() async {
        await Storage.init();
        await OfflineCache.clearAll();
        await Storage.installScript('cache_queue_fixture', script);
        await ExtensionManager.instance.init();
      });
      Future<void> waitFor(bool Function() ready) async {
        for (var attempt = 0; attempt < 400 && !ready(); attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump();
        }
        expect(ready(), isTrue);
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Column(
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const DetailPage(item: item),
                        ),
                      ),
                      child: const Text('打开目录'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const CacheListPage(),
                        ),
                      ),
                      child: const Text('打开缓存列表'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开目录'));
        await waitFor(() => find.text('缓存全部').evaluate().isNotEmpty);
        await tester.pumpAndSettle();
        await tester.tap(find.text('缓存全部'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('开始'));
        await tester.pump();
        expect(OfflineCache.instance.queue.activeCount, 3);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.byType(DetailPage), findsNothing);
        await tester.tap(find.text('打开缓存列表'));
        await tester.pump();
        await waitFor(() => OfflineCache.allEntries().length == 3);
        await tester.pumpAndSettle();
        expect(OfflineCache.instance.queue.activeCount, 0);
        expect(
          OfflineCache.readDetail(item)!.episodes.single.urls,
          hasLength(3),
        );
        expect(
          NovelWatch.fromJson(
            OfflineCache.read(item.package, '/3')!,
          ).textLines.single,
          contains('/3'),
        );
        await tester.tap(find.text('已缓存'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(item.title));
        await tester.pumpAndSettle();
        expect(find.text('第一章'), findsOneWidget);
        await tester.tap(find.byTooltip('删除缓存').first);
        await waitFor(() => OfflineCache.allEntries().length == 2);

        // Cancelling while the JS watch() is still running must not commit a
        // manifest later or start the rest of the queued batch.
        await tester.runAsync(() => OfflineCache.clearAll());
        final detail = await tester.runAsync(
          () => ExtensionManager.instance
              .byPackage(item.package)!
              .detail(item.url),
        );
        OfflineCache.instance.enqueueAll(
          item,
          detail!.episodes.single.urls,
          detail: detail,
        );
        await tester.runAsync(() => OfflineCache.instance.queue.cancelAll());
        expect(OfflineCache.allEntries(), isEmpty);
        expect(OfflineCache.instance.queue.activeCount, 0);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await OfflineCache.clearAll();
          for (final source in ExtensionManager.instance.all) {
            source.dispose();
          }
          await Hive.close();
        });
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
