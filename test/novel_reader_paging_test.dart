import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/models/reader_settings.dart';
import 'package:fusion_reader/pages/novel_reader.dart';
import 'package:fusion_reader/services/local_library.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:fusion_reader/widgets/novel_paged_view.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform originalPaths;
  late MediaItem item;
  late MediaEpisodeGroup group;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('fusion_reader_paging_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(root.path);
    await Storage.init();
    final font = FontLoader('Noto Serif CJK SC')
      ..addFont(rootBundle.load('assets/fonts/NotoSerifCJKsc-Regular.otf'));
    await font.load();
    final appFont = FontLoader('HarmonyOS Sans SC')
      ..addFont(rootBundle.load('assets/fonts/HarmonyOS_Sans_SC_Regular.ttf'));
    await appFont.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    final book = File('${root.path}${Platform.pathSeparator}book.txt');
    await book.writeAsString(
      '第1章 位置测试\n'
      '${List.generate(180, (i) => '第$i处的正文，翻页后仍能找回。').join()}\n'
      '第2章 章节测试\n第二章的短正文。\n',
    );
    item = await LocalLibrary.import(book.path, MediaType.novel);
    group = (await LocalLibrary.detail(item)).episodes.single;
  });

  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    await root.delete(recursive: true);
  });

  testWidgets(
    'reader switches modes, resumes within a paragraph and crosses chapters',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
      tester.view.viewPadding = const FakeViewPadding(top: 47, bottom: 34);
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        final settings = NovelReaderSettings.load()
          ..resetToDefaults()
          ..fontName = '衬线'
          ..paged = true;
        await settings.save();
      });
      var opened = 0;
      final capture = GlobalKey();
      Future<void> waitForChapter() async {
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          if (find.byType(NovelPagedView).evaluate().isNotEmpty) {
            await tester.pumpAndSettle();
            return;
          }
        }
        fail(
          'Chapter did not load: ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data)}',
        );
      }

      Future<void> open() async {
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(fontFamily: 'HarmonyOS Sans SC'),
              home: NovelReaderPage(
                key: ValueKey(++opened),
                item: item,
                group: group,
                groupIndex: 0,
                index: 0,
              ),
            ),
          ),
        );
        await waitForChapter();
      }

      Future<void> close() async {
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        var flushed = false;
        // Hive writes started in the widget's fake-async zone need both real
        // I/O time and pumps to complete their queued continuations.
        Future.wait([
          Storage.historyBox.flush(),
          Hive.box('settings').flush(),
        ]).then((_) => flushed = true);
        for (var i = 0; i < 100 && !flushed; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(
          flushed,
          isTrue,
          reason: 'Reading settings and history did not finish saving',
        );
        await tester.pumpAndSettle();
      }

      Future<void> switchMode(String label) async {
        await tester.tap(find.byTooltip('阅读设置'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        tester.state<NavigatorState>(find.byType(Navigator)).pop();
        await tester.pumpAndSettle();
        final paged = label == '左右翻页';
        for (
          var i = 0;
          i < 100 && NovelReaderSettings.load().paged != paged;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(NovelReaderSettings.load().paged, paged);
      }

      double page() =>
          tester.widget<PageView>(find.byType(PageView)).controller!.page!;
      NovelPagedView pager() =>
          tester.widget<NovelPagedView>(find.byType(NovelPagedView));

      try {
        await open();
        expect(page(), 0);
        await tester.drag(find.byType(PageView), const Offset(-310, 0));
        await tester.pumpAndSettle();
        await tester.tapAt(const Offset(375, 300));
        await tester.pumpAndSettle();
        final anchor = pager().position;
        final savedPage = page();
        expect(anchor.block, 2);
        expect(anchor.offset, greaterThan(0));
        // A chapter returned as one paragraph must not show 100% just because
        // the current block happens to be its last paragraph.
        expect(find.textContaining('100%'), findsNothing);
        if (const bool.fromEnvironment('CAPTURE_READING_PAGES')) {
          await tester.runAsync(() async {
            final boundary =
                capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 1);
            final png = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!;
            final file = File('build/verification/novel-pagination/page.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(
              png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
            );
            image.dispose();
          });
        }
        await close();
        expect(Storage.historyOf(item.key)!.textOffset, anchor.offset);
        await open();
        expect(page(), savedPage);
        expect(pager().position.offset, anchor.offset);
        final pageView = tester.widget<PageView>(find.byType(PageView));
        final pageRect = tester.getRect(find.byType(PageView));
        final initialCounter = tester
            .widget<Text>(find.byKey(const ValueKey('novel-page-counter')))
            .data;
        final paragraphs = find.descendant(
          of: find.byType(PageView),
          matching: find.byType(Text),
        );
        final content = [
          for (final element in paragraphs.evaluate())
            (
              (element.widget as Text).data,
              tester.getRect(find.byWidget(element.widget)),
            ),
        ];
        void expectSamePageLayout() {
          expect(
            tester.getRect(find.byType(PageView)),
            pageRect,
            reason: 'Menus must not resize the reading viewport',
          );
          expect(
            tester.widget<PageView>(find.byType(PageView)).controller,
            same(pageView.controller),
            reason: 'Menus must not trigger pagination',
          );
          expect(page(), savedPage);
          expect(
            tester
                .widget<Text>(find.byKey(const ValueKey('novel-page-counter')))
                .data,
            initialCounter,
          );
          expect(
            [
              for (final element in paragraphs.evaluate())
                (
                  (element.widget as Text).data,
                  tester.getRect(find.byWidget(element.widget)),
                ),
            ],
            content,
            reason:
                'Menus must leave the same text at the same screen coordinates',
          );
        }

        await tester.tapAt(const Offset(195, 300));
        await tester.pumpAndSettle();
        expect(find.byTooltip('阅读设置'), findsNothing);
        expect(pager().position.offset, anchor.offset);
        expectSamePageLayout();
        await tester.tapAt(const Offset(195, 300));
        await tester.pumpAndSettle();
        expect(find.byTooltip('阅读设置'), findsOneWidget);
        expect(pager().position.offset, anchor.offset);
        expectSamePageLayout();

        // Scroll mode must restore the line inside this long paragraph rather
        // than restarting its first page. Switching back keeps that line.
        await switchMode('上下滚动');
        expect(find.byType(ScrollablePositionedList), findsOneWidget);
        final scrollRect = tester.getRect(
          find.byType(ScrollablePositionedList),
        );
        final scrollController = tester
            .widget<ScrollablePositionedList>(
              find.byType(ScrollablePositionedList),
            )
            .itemScrollController;
        await tester.tapAt(const Offset(195, 300));
        await tester.pumpAndSettle();
        expect(find.byTooltip('阅读设置'), findsNothing);
        expect(
          tester.getRect(find.byType(ScrollablePositionedList)),
          scrollRect,
        );
        expect(
          tester
              .widget<ScrollablePositionedList>(
                find.byType(ScrollablePositionedList),
              )
              .itemScrollController,
          same(scrollController),
        );
        await tester.tapAt(const Offset(195, 300));
        await tester.pumpAndSettle();
        expect(find.byTooltip('阅读设置'), findsOneWidget);
        expect(
          tester.getRect(find.byType(ScrollablePositionedList)),
          scrollRect,
        );
        await switchMode('左右翻页');
        expect(page(), greaterThan(0));
        expect(pager().position.block, anchor.block);
        expect(pager().position.offset, closeTo(anchor.offset, 40));
        await close();
        expect(NovelReaderSettings.load().paged, isTrue);
        await open();
        expect(page(), greaterThan(0));

        // Going backward from the next chapter's first page opens the previous
        // chapter's LAST page, and a left swipe there advances chapters again.
        await tester.tap(find.text('下一章'));
        await waitForChapter();
        expect(Storage.historyOf(item.key)!.episodeIndex, 1);
        expect(page(), 0);
        await tester.tapAt(const Offset(5, 300));
        await waitForChapter();
        expect(Storage.historyOf(item.key)!.episodeIndex, 0);
        final counter = tester
            .widget<Text>(find.byKey(const ValueKey('novel-page-counter')))
            .data!;
        final pageCount = int.parse(counter.split('/').last.trim());
        expect(page(), pageCount - 1);
        await tester.drag(find.byType(PageView), const Offset(-310, 0));
        await waitForChapter();
        expect(Storage.historyOf(item.key)!.episodeIndex, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await close();
        var closed = false;
        Hive.close().then((_) => closed = true);
        for (var i = 0; i < 100 && !closed; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(closed, isTrue);
      }
    },
  );
}
