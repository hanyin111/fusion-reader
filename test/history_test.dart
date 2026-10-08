import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
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
  package: 'fixture',
  type: MediaType.novel,
  title: '未收藏的小说',
  url: '/novel',
);
const comic = MediaItem(
  package: 'fixture',
  type: MediaType.manga,
  title: '未收藏的漫画',
  url: '/comic',
);

HistoryRecord progress(MediaItem item, int timestamp, {bool metadata = true}) =>
    HistoryRecord(
      key: item.key,
      item: metadata ? item : null,
      episodeUrl: '/chapter/2',
      episodeName: '第二章',
      groupIndex: 1,
      episodeIndex: 2,
      timestamp: timestamp,
      position: 37,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late PathProviderPlatform originalPaths;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('fusion_history_unit_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(root.path);
    await Storage.init();
  });
  setUp(() async {
    await Storage.clearHistory();
    await Storage.favoritesBox.clear();
    await Storage.localBox.clear();
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    await root.delete(recursive: true);
  });

  test(
    'browsing an unfavorited work stores metadata without a fake resume point',
    () async {
      await Storage.recordVisit(novel);
      expect(Storage.favorites(), isEmpty);
      expect(Storage.historyOf(novel.key), isNull);
      expect(Storage.history().single.item!.title, novel.title);
      expect(Storage.history().single.hasProgress, isFalse);
      await Storage.recordVisit(novel);
      expect(Storage.history(), hasLength(1));
    },
  );

  test(
    'detail visits and sparse reader metadata preserve the chapter and position',
    () async {
      await Storage.saveHistory(progress(novel, 10));
      const enriched = MediaItem(
        package: 'fixture',
        type: MediaType.novel,
        title: '完整书名',
        url: '/novel',
        cover: 'https://example.test/cover.jpg',
      );
      await Storage.recordVisit(enriched);
      final resumed = Storage.historyOf(novel.key)!;
      expect(resumed.episodeUrl, '/chapter/2');
      expect(resumed.groupIndex, 1);
      expect(resumed.episodeIndex, 2);
      expect(resumed.position, 37);
      await Storage.saveHistory(resumed.copyWith(position: 38), item: novel);
      expect(Storage.historyOf(novel.key)!.item!.cover, enriched.cover);
      expect(Storage.historyOf(novel.key)!.position, 38);
    },
  );

  test(
    'old progress is readable, and startup fills missing metadata from favorites',
    () async {
      final old = progress(novel, 123, metadata: false);
      await Storage.historyBox.put(novel.key, old.toJson());
      expect(Storage.historyOf(novel.key)!.position, 37);
      await Storage.toggleFavorite(novel);
      await Storage.historyBox.close();
      await Storage.init();
      final restored = Storage.historyOf(novel.key)!;
      expect(restored.item!.title, novel.title);
      expect(restored.timestamp, 123);
      expect(restored.position, 37);
    },
  );

  test(
    'unfavorited records survive reopening storage and remain ordered by recency',
    () async {
      await Storage.saveHistory(progress(novel, 100));
      await Storage.saveHistory(progress(comic, 200));
      await Storage.historyBox.close();
      await Storage.init();
      expect(Storage.history().map((record) => record.item!.title), [
        comic.title,
        novel.title,
      ]);
      expect(Storage.favorites(), isEmpty);
      expect(Storage.historyOf(novel.key)!.position, 37);
    },
  );

  test(
    'identical work URLs in separate sources remain separate records',
    () async {
      await Storage.recordVisit(novel);
      await Storage.recordVisit(
        const MediaItem(
          package: 'another',
          type: MediaType.novel,
          title: '另一个来源',
          url: '/novel',
        ),
      );
      expect(Storage.history(), hasLength(2));
    },
  );
}
