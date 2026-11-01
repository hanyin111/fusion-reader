import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/pages/manga_reader.dart';
import 'package:fusion_reader/services/local_library.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'manga_reader_zoom_test.dart' show TestPaths;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform originalPaths;
  late MediaItem item;
  late MediaEpisodeGroup group;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('fusion_continuous_comic_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = TestPaths(root.path);
    await Storage.init();
    final book = Directory('${root.path}/comic')..createSync();
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    for (var c = 1; c <= 3; c++) {
      final directory = Directory('${book.path}/chapter$c')..createSync();
      for (var p = 1; p <= 6; p++) {
        await File('${directory.path}/$p.png').writeAsBytes(png);
      }
    }
    item = await LocalLibrary.import(book.path, MediaType.manga);
    group = (await LocalLibrary.detail(item)).episodes.single;
    await Storage.setSetting('mangaWebtoon', true);
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    if (root.parent.absolute.path.toLowerCase() !=
            Directory.systemTemp.absolute.path.toLowerCase() ||
        !root.uri.pathSegments.any(
          (part) => part.startsWith('fusion_continuous_comic_'),
        )) {
      throw StateError(
        'Refusing to remove a directory outside the test fixture',
      );
    }
    await root.delete(recursive: true);
  });

  testWidgets(
    'scroll appends chapters without moving the viewport and resumes the visible chapter',
    (tester) async {
      tester.view.physicalSize = const Size(360, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Future<void> settle() async {
        for (var i = 0; i < 25; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 40));
        }
        expect(tester.takeException(), isNull);
      }

      Widget reader(int chapter) => MaterialApp(
        home: MangaReaderPage(
          item: item,
          group: group,
          groupIndex: 0,
          index: chapter,
        ),
      );
      await tester.pumpWidget(reader(0));
      await settle();
      var list = tester.widget<ScrollablePositionedList>(
        find.byType(ScrollablePositionedList),
      );
      final stripKey = list.key;
      expect(list.itemCount, 7); // No fetch while still at the beginning.
      list.itemScrollController!.jumpTo(index: 4);
      await settle();
      list = tester.widget<ScrollablePositionedList>(
        find.byType(ScrollablePositionedList),
      );
      expect(list.itemCount, 13);
      expect(list.key, stripKey);
      expect(Storage.historyOf(item.key)!.episodeIndex, 0);
      expect(Storage.historyOf(item.key)!.position, 4);
      // A real drag carries us across the boundary, without a chapter-button tap.
      await tester.dragFrom(const Offset(170, 350), const Offset(0, -900));
      await settle();
      expect(Storage.historyOf(item.key)!.episodeIndex, 1);
      expect(Storage.historyOf(item.key)!.position, inInclusiveRange(0, 2));
      expect(find.textContaining('· ${group.urls[1].name}'), findsOneWidget);
      expect(
        tester
            .widget<ScrollablePositionedList>(
              find.byType(ScrollablePositionedList),
            )
            .key,
        stripKey,
      );
      // Reverse scrolling still addresses the original chapter and page.
      list.itemScrollController!.jumpTo(index: 5);
      await settle();
      expect(Storage.historyOf(item.key)!.episodeIndex, 0);
      expect(Storage.historyOf(item.key)!.position, 5);
      list.itemScrollController!.jumpTo(index: 8);
      await settle();
      expect(Storage.historyOf(item.key)!.episodeIndex, 1);
      expect(Storage.historyOf(item.key)!.position, 2);
      await tester.tap(find.byTooltip('切换为翻页模式'));
      await settle();
      expect(find.byType(PageView), findsOneWidget);
      expect(find.text('3/6'), findsOneWidget);
      await tester.tap(find.byTooltip('切换为条漫模式'));
      await settle();
      expect(Storage.historyOf(item.key)!.episodeIndex, 1);
      expect(Storage.historyOf(item.key)!.position, 2);
      list = tester.widget<ScrollablePositionedList>(
        find.byType(ScrollablePositionedList),
      );
      list.itemScrollController!.jumpTo(index: 18);
      await settle();
      expect(find.text('已读到最后一章'), findsOneWidget);
      list.itemScrollController!.jumpTo(index: 16);
      await settle();
      expect(Storage.historyOf(item.key)!.episodeIndex, 2);
      expect(Storage.historyOf(item.key)!.position, 4);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await settle();
      await tester.pumpWidget(reader(2));
      await settle();
      expect(find.text('5/6'), findsOneWidget);
      expect(Storage.historyOf(item.key)!.episodeIndex, 2);
      expect(Storage.historyOf(item.key)!.position, 4);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await settle();
      var closed = false;
      Hive.close().then((_) => closed = true);
      for (var i = 0; i < 100 && !closed; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(closed, isTrue);
    },
  );
}
