import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/services/extension_manager.dart';
import 'package:fusion_reader/services/offline_cache.dart';
import 'package:fusion_reader/services/sources.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'linovelib_test.dart' show isolateLinovelibTestStorage;

void main() {
  isolateLinovelibTestStorage();
  testWidgets(
    'old truncated cache is fetched again; complete cache stays offline',
    (tester) async {
      await tester.runAsync(() async {
        await Storage.init();
        const script = '''
// ==MiruExtension==
// @name Cache regression fixture
// @version v1.0.0
// @package linovelib
// @type fikushon
// @webSite https://www.bilinovel.net
// ==/MiruExtension==
export default class extends Extension {
  async watch(url) { return {content: ['重新读取完整正文：' + url]}; }
}
''';
        await Storage.installScript('linovelib', script);
        final manager = ExtensionManager.instance;
        await manager.init();
        const item = MediaItem(
          package: 'linovelib',
          type: MediaType.novel,
          title: '缓存回归',
          url: '/novel/1.html',
        );
        final manifests = Hive.box('offline_manifests');
        try {
          const incomplete = '/novel/1/2.html';
          await manifests.put(OfflineCache.keyOf('linovelib', incomplete), {
            'payload': {
              'content': ['内容加载失败，请更换浏览器'],
            },
          });
          final reloaded = await Sources.watchCached(item, incomplete);
          expect(NovelWatch.fromJson(reloaded).textLines, [
            '重新读取完整正文：$incomplete',
          ]);

          const complete = '/novel/1/3.html';
          await manifests.put(OfflineCache.keyOf('linovelib', complete), {
            'payload': {
              'content': ['已下载的完整正文'],
            },
          });
          final cached = await Sources.watchCached(item, complete);
          expect(NovelWatch.fromJson(cached).textLines, ['已下载的完整正文']);
        } finally {
          await Storage.uninstallScript('linovelib');
          for (final service in manager.all) {
            service.dispose();
          }
        }
      });
      await tester.pump();
    },
  );
}
