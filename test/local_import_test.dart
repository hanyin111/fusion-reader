import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/pages/library_page.dart';
import 'package:fusion_reader/services/local_library.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:fusion_reader/widgets/media_card.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'extension_repository_settings_test.dart' show TestPaths;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform paths;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('fusion_local_import_');
    paths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = TestPaths(root.path);
    await Storage.init();
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = paths;
    await root.delete(recursive: true);
  });

  test(
    'empty folders are rejected before any library record is written',
    () async {
      final directory = await Directory('${root.path}/empty').create();
      await Directory('${directory.path}/unrelated').create();
      final before = LocalLibrary.all().length;
      await expectLater(
        LocalLibrary.import(directory.path, MediaType.manga),
        throwsException,
      );
      expect(LocalLibrary.all().length, before);
    },
  );

  test(
    'copied chapter folders appear in natural order and ignore empty folders',
    () async {
      final directory = await Directory('${root.path}/comic').create();
      for (final chapter in ['10', '2']) {
        final sub = await Directory('${directory.path}/$chapter').create();
        await File('${sub.path}/1.png').writeAsBytes([1]);
      }
      await Directory('${directory.path}/unused').create();
      final item = await LocalLibrary.import(directory.path, MediaType.manga);
      final detail = await LocalLibrary.detail(item);
      expect(detail.episodes.single.urls.map((e) => e.name), ['2', '10']);
      expect(LocalLibrary.all().any((e) => e.key == item.key), isTrue);
    },
  );

  testWidgets(
    'canceling a local favorite keeps one shelf entry until removal',
    (tester) async {
      Future<void> waitFor(bool Function() ready) async {
        for (var i = 0; i < 100 && !ready(); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(ready(), isTrue);
        await tester.pumpAndSettle();
      }

      late MediaItem book;
      late File source;
      await tester.runAsync(() async {
        await Storage.favoritesBox.clear();
        await Storage.localBox.clear();
        await Storage.clearHistory();
        source = await File('${root.path}/本地测试.txt').writeAsString('第一章\n本地正文');
        book = await LocalLibrary.import(source.path, MediaType.novel);
        await Storage.toggleFavorite(book);
      });

      await tester.pumpWidget(const MaterialApp(home: LibraryPage()));
      final card = find.widgetWithText(MediaCard, book.title);
      expect(card, findsOneWidget);
      await tester.tap(card);
      final chapterList = find.textContaining('共 1 个章节');
      await waitFor(() => chapterList.evaluate().isNotEmpty);

      await tester.tap(find.byTooltip('取消收藏'));
      await waitFor(() => !Storage.isFavorite(book.key));
      expect(find.byTooltip('收藏'), findsOneWidget);
      expect(Storage.isFavorite(book.key), isFalse);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(card, findsOneWidget);

      await tester.tap(find.byTooltip(RegExp('书架管理')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('从书架移除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移除'));
      await waitFor(() => !Storage.localBox.containsKey(book.url));
      expect(card, findsNothing);
      expect(Storage.isFavorite(book.key), isFalse);
      expect(source.existsSync(), isTrue);
      await tester.pumpWidget(const SizedBox());
      var closed = false;
      Storage.localBox
          .flush()
          .then((_) => Storage.favoritesBox.flush())
          .then((_) => Storage.historyBox.flush())
          .then((_) => Hive.close())
          .then((_) => closed = true);
      await waitFor(() => closed);
    },
  );
}
