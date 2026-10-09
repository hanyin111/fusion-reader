import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/pages/detail_page.dart';
import 'package:fusion_reader/pages/manga_reader.dart';
import 'package:fusion_reader/pages/novel_reader.dart';
import 'package:fusion_reader/services/local_library.dart';
import 'package:fusion_reader/services/offline_cache.dart';
import 'package:fusion_reader/services/sources.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TestPaths extends PathProviderPlatform {
  final String root;
  _TestPaths(this.root);
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

const novel = MediaItem(
  package: 'offline_fixture',
  type: MediaType.novel,
  title: '缓存小说',
  url: '/novel',
);
const manga = MediaItem(
  package: 'offline_comic_fixture',
  type: MediaType.manga,
  title: '缓存漫画',
  url: '/manga',
);
const second = MediaEpisode(name: '第二章', url: '/chapter/2');
const third = MediaEpisode(name: '第三章', url: '/chapter/3');
const catalog = MediaDetail(
  title: '完整书名',
  cover: '',
  desc: '作品简介',
  authors: [MediaAuthor(name: '作者', id: '7', url: '/author/7')],
  episodes: [
    MediaEpisodeGroup(
      title: '第一卷',
      urls: [MediaEpisode(name: '第一章', url: '/chapter/1')],
    ),
    MediaEpisodeGroup(title: '第二卷', urls: [second, third]),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform originalPaths;
  late File image;
  Future<void> seed(
    MediaItem item,
    MediaEpisode episode, {
    String? probe,
  }) => Hive.box('offline_manifests').put(
    OfflineCache.keyOf(item.package, episode.url),
    {
      'key': OfflineCache.keyOf(item.package, episode.url),
      'package': item.package,
      'itemKey': item.key,
      'itemTitle': item.title,
      'itemUrl': item.url,
      'type': item.type.name,
      'episodeUrl': episode.url,
      'episodeName': episode.name,
      'payload': item.type == MediaType.novel
          ? {'content': List.generate(60, (index) => '已下载的第 ${index + 1} 段正文')}
          : {
              'urls': [image.path, image.path],
            },
      'probe': probe ?? '',
      'bytes': 10,
    },
  );

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('fusion_offline_catalog_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(root.path);
    await Storage.init();
    image = File('${root.path}${Platform.pathSeparator}page.png');
    await image.writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
      ),
    );
  });
  setUp(() async {
    await OfflineCache.clearAll();
    await Storage.clearHistory();
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    await root.delete(recursive: true);
  });

  test(
    'complete catalogs persist, update and open without an installed source',
    () async {
      await seed(novel, second);
      await OfflineCache.saveDetail(novel, catalog);
      await Hive.close();
      await Storage.init();
      final cached = await Sources.detail(novel);
      expect(cached.toJson(), catalog.toJson());
      expect(cached.episodes[1].urls.map((ep) => ep.url), [
        second.url,
        third.url,
      ]);
      await OfflineCache.saveDetail(
        novel,
        const MediaDetail(title: '空目录', cover: '', desc: '', episodes: []),
      );
      expect(OfflineCache.readDetail(novel)!.title, catalog.title);
      final updated = MediaDetail(
        title: catalog.title,
        cover: '',
        desc: '更新的简介',
        episodes: catalog.episodes,
      );
      await OfflineCache.saveDetail(novel, updated);
      expect(OfflineCache.readDetail(novel)!.desc, updated.desc);
      expect(
        OfflineCache.allEntries(),
        hasLength(1),
        reason: 'Catalogs must not count as downloaded chapters',
      );
    },
  );

  test(
    'old downloads provide a chapter list and keep source/work identities separate',
    () async {
      await seed(novel, second);
      await seed(novel, third, probe: '${root.path}/missing');
      await seed(manga, const MediaEpisode(name: '别的漫画', url: '/comic/2'));
      final legacy = await Sources.detail(novel);
      expect(legacy.episodes.single.title, '已缓存章节');
      expect(legacy.episodes.single.urls.map((ep) => ep.url), [second.url]);
      expect(
        OfflineCache.readDetail(
          const MediaItem(
            package: 'other_source',
            type: MediaType.novel,
            title: '同网址',
            url: '/novel',
          ),
        ),
        isNull,
      );
      await expectLater(
        Sources.detail(
          const MediaItem(
            package: 'offline_fixture',
            type: MediaType.novel,
            title: '没有下载',
            url: '/empty',
          ),
        ),
        throwsException,
      );
    },
  );

  test(
    'catalog lifetime follows the last chapter and clear removes both stores',
    () async {
      await seed(novel, second);
      await seed(novel, third);
      await seed(manga, second);
      await OfflineCache.saveDetail(novel, catalog);
      await OfflineCache.saveDetail(manga, catalog);
      await OfflineCache.remove(novel.package, second.url);
      expect(OfflineCache.readDetail(novel)!.episodes, hasLength(2));
      await OfflineCache.remove(novel.package, third.url);
      expect(OfflineCache.readDetail(novel), isNull);
      expect(OfflineCache.readDetail(manga), isNotNull);
      await OfflineCache.clearAll();
      expect(Hive.box('offline_catalogs').isEmpty, isTrue);
      expect(OfflineCache.allEntries(), isEmpty);
    },
  );

  test(
    'a real chapter download also stores the supplied full directory',
    () async {
      final file = File('${root.path}${Platform.pathSeparator}book.txt');
      await file.writeAsString('第一章 本地测试\n正文\n第二章 结尾\n结束\n');
      final item = await LocalLibrary.import(file.path, MediaType.novel);
      final detail = await LocalLibrary.detail(item);
      final episode = detail.episodes.single.urls.first;
      await OfflineCache.instance.download(item, episode, detail: detail);
      expect(OfflineCache.readDetail(item)!.toJson(), detail.toJson());
      await file.delete();
      final downloaded = await Sources.watchCached(item, episode.url);
      expect(NovelWatch.fromJson(downloaded).textLines, contains('正文'));
      expect(OfflineCache.readDetail(item)!.episodes.single.urls, hasLength(2));
    },
  );

  testWidgets(
    'offline directories open cached novels and comics and resume by URL',
    (tester) async {
      Future<void> waitFor(bool Function() ready) async {
        for (var i = 0; i < 100 && !ready(); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(ready(), isTrue);
        await tester.pumpAndSettle();
      }

      Future<void> closeReader() async {
        await tester.pumpWidget(const SizedBox());
        var flushed = false;
        Storage.historyBox.flush().then((_) => flushed = true);
        await waitFor(() => flushed);
      }

      // Seed before mounting widgets: later Hive writes belong to the
      // widget fake-async zone and are drained with pumps below.
      await tester.runAsync(() async {
        for (final item in [novel, manga]) {
          await seed(item, second);
          if (item == novel) await OfflineCache.saveDetail(item, catalog);
          // Deliberately obsolete indexes: legacy caches have a compact list.
          await Storage.saveHistory(
            HistoryRecord(
              key: item.key,
              item: item,
              episodeUrl: second.url,
              episodeName: second.name,
              groupIndex: 8,
              episodeIndex: 19,
              timestamp: 1,
              position: item == novel ? 20 : 1,
            ),
          );
        }
      });
      try {
        for (final item in [novel, manga]) {
          await tester.pumpWidget(
            MaterialApp(
              home: DetailPage(key: ValueKey(item.key), item: item),
            ),
          );
          await waitFor(() => find.textContaining('共 ').evaluate().isNotEmpty);
          expect(find.textContaining('加载失败'), findsNothing);
          expect(find.byTooltip('已缓存，点击删除'), findsOneWidget);
          await tester.tap(find.text('继续: 第二章'));
          if (item == novel) {
            await waitFor(
              () => find.byType(NovelReaderPage).evaluate().isNotEmpty,
            );
            expect(find.byType(NovelReaderPage), findsOneWidget);
            await waitFor(
              () => find.textContaining('已下载的第 20 段正文').evaluate().isNotEmpty,
            );
            expect(Storage.historyOf(item.key)!.position, 20);
          } else {
            await waitFor(
              () => find.byType(MangaReaderPage).evaluate().isNotEmpty,
            );
            expect(find.byType(MangaReaderPage), findsOneWidget);
            await waitFor(() => find.byType(PageView).evaluate().isNotEmpty);
            expect(
              tester.widget<PageView>(find.byType(PageView)).controller!.page,
              1,
            );
          }
          expect(Storage.historyOf(item.key)!.episodeUrl, second.url);
          expect(tester.takeException(), isNull);
          await closeReader();
        }
      } finally {
        await closeReader();
        var closed = false;
        Hive.close().then((_) => closed = true);
        await waitFor(() => closed);
      }
    },
  );
}
