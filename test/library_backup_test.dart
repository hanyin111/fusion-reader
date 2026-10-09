import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/services/library_backup.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'history_test.dart' show novel, comic, progress;

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

LibraryBackup fromJson(Map<String, dynamic> json) =>
    LibraryBackup.decode(utf8.encode(jsonEncode(json)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform originalPaths;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('fusion_backup_unit_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(root.path);
    await Storage.init();
  });
  setUp(() async {
    await Storage.favoritesBox.clear();
    await Storage.clearHistory();
    await Storage.localBox.clear();
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    await root.delete(recursive: true);
  });

  test(
    'cross-device round trip restores shelf ordering, visits and chapter positions',
    () async {
      const video = MediaItem(
        package: 'video',
        type: MediaType.anime,
        title: '动画',
        url: '/watch',
      );
      await Storage.toggleFavorite(novel);
      await Storage.toggleFavorite(comic);
      await Storage.toggleFavorite(video);
      await Storage.saveHistory(progress(novel, 100));
      await Storage.saveHistory(progress(comic, 200).copyWith(position: 12));
      await Storage.saveHistory(
        progress(video, 300).copyWith(position: 123456),
      );
      const visit = MediaItem(
        package: 'another',
        type: MediaType.novel,
        title: '仅浏览',
        url: '/book',
      );
      await Storage.recordVisit(visit);
      final originalShelf = Storage.favorites()
          .map((item) => item.key)
          .toList();
      final originalHistory = Storage.history()
          .map((record) => record.toJson())
          .toList();
      final backup = LibraryBackup.decode(
        LibraryBackup.capture().encodeBytes(),
      );
      await Storage.favoritesBox.clear();
      await Storage.clearHistory();
      final result = await backup.merge();
      expect(result.addedFavorites, 3);
      expect(result.addedHistory, 4);
      await Storage.favoritesBox.close();
      await Storage.historyBox.close();
      await Storage.init();
      expect(Storage.favorites().map((item) => item.key), originalShelf);
      expect(
        Storage.history().map((record) => record.toJson()),
        originalHistory,
      );
      expect(Storage.historyOf(video.key)!.position, 123456);
      expect(Storage.historyOf(visit.key), isNull);
    },
  );

  test(
    'repeated import is idempotent and leaves newer local progress untouched',
    () async {
      await Storage.toggleFavorite(novel);
      await Storage.saveHistory(progress(novel, 100));
      final oldBackup = LibraryBackup.decode(
        LibraryBackup.capture().encodeBytes(),
      );
      await Storage.saveHistory(progress(novel, 200).copyWith(position: 55));
      await Storage.toggleFavorite(comic);
      await Storage.saveHistory(progress(comic, 300));
      final result = await oldBackup.merge();
      expect(
        result.addedFavorites +
            result.updatedFavorites +
            result.addedHistory +
            result.updatedHistory,
        0,
      );
      expect(Storage.historyOf(novel.key)!.position, 55);
      expect(Storage.favorites(), hasLength(2));
      expect(Storage.history(), hasLength(2));
      await oldBackup.merge();
      expect(Storage.historyOf(novel.key)!.timestamp, 200);
      expect(Storage.favorites(), hasLength(2));
    },
  );

  test(
    'newer incoming progress wins while older metadata fills missing cover',
    () async {
      const enriched = MediaItem(
        package: 'fixture',
        type: MediaType.novel,
        title: '小说',
        url: '/novel',
        cover: 'https://example.test/cover.jpg',
      );
      await Storage.saveHistory(progress(novel, 300).copyWith(position: 88));
      final backup = LibraryBackup.decode(
        LibraryBackup.capture().encodeBytes(),
      );
      await Storage.saveHistory(progress(enriched, 100));
      final result = await backup.merge();
      expect(result.updatedHistory, 1);
      expect(Storage.historyOf(novel.key)!.position, 88);
      expect(Storage.historyOf(novel.key)!.item!.cover, enriched.cover);
      final repeated = await backup.merge();
      expect(repeated.updatedHistory, 0);
    },
  );

  test('newer visit never erases a saved chapter on either device', () async {
    await Storage.recordVisit(novel);
    final visitBackup = LibraryBackup.decode(
      LibraryBackup.capture().encodeBytes(),
    );
    await Storage.saveHistory(progress(novel, 100));
    await visitBackup.merge();
    expect(Storage.historyOf(novel.key)!.position, 37);
    expect(
      Storage.historyOf(novel.key)!.timestamp,
      visitBackup.history.single.timestamp,
    );
    final progressBackup = LibraryBackup.decode(
      LibraryBackup.capture().encodeBytes(),
    );
    await Storage.clearHistory();
    await Storage.recordVisit(novel);
    await progressBackup.merge();
    expect(Storage.historyOf(novel.key)!.position, 37);
    expect(Storage.history(), hasLength(1));
  });

  test(
    'legacy records without metadata and URLs containing pipes remain recoverable',
    () async {
      const item = MediaItem(
        package: 'legacy',
        type: MediaType.novel,
        title: '旧记录',
        url: '/book|edition=2',
      );
      await Storage.saveHistory(progress(item, 99, metadata: false));
      final backup = LibraryBackup.decode(
        LibraryBackup.capture().encodeBytes(),
      );
      await Storage.clearHistory();
      await backup.merge();
      expect(Storage.historyOf(item.key)!.item, isNull);
      expect(Storage.historyOf(item.key)!.episodeUrl, '/chapter/2');
    },
  );

  test(
    'source identity prevents collisions and unknown sources keep their data',
    () async {
      const other = MediaItem(
        package: 'uninstalled',
        type: MediaType.novel,
        title: '另一个源',
        url: '/novel',
      );
      await Storage.toggleFavorite(novel);
      await Storage.toggleFavorite(other);
      await Storage.saveHistory(progress(other, 123));
      final backup = LibraryBackup.decode(
        LibraryBackup.capture().encodeBytes(),
      );
      await Storage.favoritesBox.clear();
      await Storage.clearHistory();
      await backup.merge();
      expect(Storage.favorites(), hasLength(2));
      expect(Storage.historyOf(other.key)!.item!.title, other.title);
      expect(backup.packages, containsAll(['fixture', 'uninstalled']));
    },
  );

  test(
    'device-local paths and account credentials never enter the portable file',
    () async {
      const local = MediaItem(
        package: 'local',
        type: MediaType.novel,
        title: '本地书',
        url: 'C:/books/private.txt',
      );
      await Storage.toggleFavorite(local);
      await Storage.saveHistory(progress(local, 123));
      await Storage.setExtSetting('picacg', 'password', 'backup-test-secret');
      await Storage.toggleFavorite(novel);
      final backup = LibraryBackup.capture();
      final text = backup.encode();
      expect(backup.excludedLocalFavorites, 1);
      expect(backup.excludedLocalHistory, 1);
      expect(text, isNot(contains('C:/books/private.txt')));
      expect(text, isNot(contains('backup-test-secret')));
      final json = jsonDecode(text) as Map<String, dynamic>;
      json['favorites'] = [local.toJson(), novel.toJson()];
      json['history'] = [progress(local, 123).toJson()];
      final parsed = fromJson(json);
      await parsed.merge();
      expect(Storage.historyOf(local.key)!.position, 37);
      expect(parsed.favorites.single.key, novel.key);
      expect(parsed.history, isEmpty);
    },
  );

  test(
    'duplicate entries in a file are merged using the latest progress',
    () async {
      await Storage.toggleFavorite(novel);
      final json =
          jsonDecode(LibraryBackup.capture().encode()) as Map<String, dynamic>;
      json['favorites'] = [novel.toJson(), novel.toJson()];
      json['history'] = [
        progress(novel, 200).copyWith(position: 80).toJson(),
        progress(novel, 100).toJson(),
      ];
      final backup = fromJson(json);
      expect(backup.favorites, hasLength(1));
      expect(backup.history, hasLength(1));
      await backup.merge();
      expect(Storage.historyOf(novel.key)!.position, 80);
      expect(Storage.history(), hasLength(1));
    },
  );

  test(
    'invalid files and versions fail completely before changing existing data',
    () async {
      await Storage.toggleFavorite(novel);
      await Storage.saveHistory(progress(novel, 200));
      final original = LibraryBackup.capture().encode();
      final good = jsonDecode(original) as Map<String, dynamic>;
      final badFiles = [
        <String, dynamic>{...good, 'format': 'OtherApp'},
        <String, dynamic>{...good, 'schemaVersion': 2},
        <String, dynamic>{...good, 'schemaVersion': 1.0},
        <String, dynamic>{...good, 'exportedAt': 'invalid'},
        <String, dynamic>{...good, 'favorites': {}},
        <String, dynamic>{
          ...good,
          'favorites': [
            comic.toJson(),
            {...novel.toJson(), 'type': 'invalid'},
          ],
        },
        <String, dynamic>{
          ...good,
          'history': [
            {...progress(novel, 100).toJson(), 'key': comic.key},
          ],
        },
        <String, dynamic>{
          ...good,
          'history': [
            {...progress(novel, 100).toJson(), 'key': 'invalid'},
          ],
        },
        for (final field in [
          'position',
          'timestamp',
          'episodeIndex',
          'groupIndex',
        ])
          <String, dynamic>{
            ...good,
            'history': [
              {...progress(novel, 100).toJson(), field: -1},
            ],
          },
        <String, dynamic>{
          ...good,
          'history': [
            {...progress(novel, 100).toJson(), 'position': 1.2},
          ],
        },
        <String, dynamic>{
          ...good,
          'history': [
            {...progress(novel, 100).toJson(), 'timestamp': 9007199254740991},
          ],
        },
      ];
      for (final bad in badFiles) {
        expect(() => fromJson(bad), throwsFormatException);
      }
      expect(() => LibraryBackup.decode([0xff]), throwsFormatException);
      expect(
        () => LibraryBackup.decode(utf8.encode('{')),
        throwsFormatException,
      );
      expect(
        () => LibraryBackup.decode(utf8.encode('[]')),
        throwsFormatException,
      );
      expect(Storage.favorites().single.key, novel.key);
      expect(Storage.historyOf(novel.key)!.timestamp, 200);
    },
  );

  test(
    'UTF-8 BOM is supported and unreasonable size/count is rejected',
    () async {
      final backup = LibraryBackup.capture();
      final bom = [
        ...[0xef, 0xbb, 0xbf],
        ...backup.encodeBytes(),
      ];
      expect(LibraryBackup.decode(bom).favorites, isEmpty);
      expect(
        () => LibraryBackup.decode(List.filled(LibraryBackup.maxBytes + 1, 32)),
        throwsFormatException,
      );
      final json = jsonDecode(backup.encode()) as Map<String, dynamic>;
      json['favorites'] = List.filled(
        LibraryBackup.maxRecords + 1,
        novel.toJson(),
      );
      expect(() => fromJson(json), throwsFormatException);
    },
  );
}
