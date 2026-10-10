import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/pages/manga_reader.dart';
import 'package:fusion_reader/services/local_library.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:fusion_reader/widgets/manga_zoom_view.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

class TestPaths extends PathProviderPlatform {
  final String root;
  TestPaths(this.root);
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform paths;
  late MediaItem item;
  late MediaEpisodeGroup group;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('fusion_comic_zoom_');
    paths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = TestPaths(root.path);
    await Storage.init();
    final book = Directory('${root.path}/comic')..createSync();
    for (var chapter = 1; chapter <= 2; chapter++) {
      final directory = Directory('${book.path}/chapter$chapter')..createSync();
      for (var page = 1; page <= 3; page++) {
        await File(
          'assets/icon/whitehair-girl-1024.png',
        ).copy('${directory.path}/$page.png');
      }
    }
    item = await LocalLibrary.import(book.path, MediaType.manga);
    group = (await LocalLibrary.detail(item)).episodes.single;
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = paths;
    final temporary = Directory.systemTemp.absolute.path.toLowerCase();
    if (!root.absolute.path.toLowerCase().startsWith(
          '$temporary${Platform.pathSeparator}',
        ) ||
        !root.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('fusion_comic_zoom_')) {
      throw StateError(
        'Refusing to remove a directory outside the temporary fixture',
      );
    }
    await root.delete(recursive: true);
  });

  testWidgets(
    'reader controls fit a narrow phone, zoom both modes, and reset on chapter changes',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Future<void> waitForLoad() async {
        for (var i = 0; i < 30; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          if (find.byType(MangaZoomView).evaluate().isNotEmpty) {
            await tester.pumpAndSettle();
            return;
          }
        }
        fail('Local comic did not load');
      }

      await tester.pumpWidget(
        MaterialApp(
          home: MangaReaderPage(
            item: item,
            group: group,
            groupIndex: 0,
            index: 0,
          ),
        ),
      );
      await waitForLoad();
      expect(find.text('100%'), findsOneWidget);
      await tester.tap(find.byTooltip('放大'));
      await tester.pumpAndSettle();
      expect(find.text('150%'), findsOneWidget);
      await tester.tap(find.byTooltip('切换为条漫模式'));
      await tester.pumpAndSettle();
      expect(find.byType(ScrollablePositionedList), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);
      await tester.tap(find.byTooltip('放大'));
      await tester.pumpAndSettle();
      expect(find.text('150%'), findsOneWidget);
      await tester.tap(find.byTooltip('下一章'));
      await waitForLoad();
      expect(find.text('100%'), findsOneWidget);
      expect(
        tester
            .widget<InteractiveViewer>(find.byType(InteractiveViewer))
            .transformationController!
            .value
            .getMaxScaleOnAxis(),
        1,
      );
      expect(find.text('1/3'), findsOneWidget);
      await tester.tap(find.byTooltip('切换为翻页模式'));
      await tester.pumpAndSettle();
      expect(find.byType(PageView), findsOneWidget);
      await tester.tap(find.byTooltip('放大'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('150%'));
      await tester.pumpAndSettle();
      expect(find.text('100%'), findsOneWidget);
      await tester.dragFrom(const Offset(290, 350), const Offset(-250, 0));
      await tester.pumpAndSettle();
      expect(find.text('2/3'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      var flushed = false;
      Future.wait([
        Storage.settingsBox.flush(),
        Storage.historyBox.flush(),
      ]).then((_) => flushed = true);
      for (var i = 0; i < 100 && !flushed; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(flushed, isTrue);
      expect(Storage.historyOf(item.key)!.position, 1);
      expect(Storage.historyOf(item.key)!.episodeIndex, 1);
      // Pump the zone that owns the reader's writes while closing the boxes.
      // Awaiting close in runAsync would leave those continuations suspended.
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
