import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/models/reader_settings.dart';
import 'package:fusion_reader/services/novel_pagination.dart';
import 'package:fusion_reader/widgets/novel_paged_view.dart';

NovelReaderSettings settings() => NovelReaderSettings(
  fontSize: 18,
  lineHeight: 1.7,
  paragraphSpacing: 12,
  horizontalPadding: 20,
  verticalPadding: 16,
  letterSpacing: 0,
  fontWeightIndex: 0,
  indentFirstLine: true,
  justify: false,
  fontName: '鸿蒙黑体',
  themeName: '跟随应用',
  paged: true,
);

const bodyStyle = TextStyle(
  fontSize: 18,
  height: 1.7,
  fontFamily: 'HarmonyOS Sans SC',
);
NovelPagination layout(
  List<NovelBlock> blocks, {
  Size size = const Size(300, 480),
  double fontSize = 18,
  double scale = 1,
}) => NovelPagination.layout(
  blocks: blocks,
  title: '章节标题',
  size: size,
  style: bodyStyle.copyWith(fontSize: fontSize),
  titleStyle: bodyStyle.copyWith(fontSize: fontSize * 1.4, height: 1.4),
  textScaler: TextScaler.linear(scale),
  direction: TextDirection.ltr,
  indent: true,
  justify: true,
  paragraphSpacing: 12,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader('HarmonyOS Sans SC')
      ..addFont(rootBundle.load('assets/fonts/HarmonyOS_Sans_SC_Regular.ttf'));
    await font.load();
  });

  test(
    'long paragraphs retain every character and split only at graphemes',
    () {
      final text = List.filled(
        75,
        '中文👨‍👩‍👧‍👦e\u0301 English words.\n',
      ).join();
      final result = layout([NovelBlock.text(text)]);
      expect(result.pages.length, greaterThan(2));
      final parts = result.pages
          .expand((p) => p.fragments)
          .where((p) => p.start.block == 1)
          .toList();
      expect(parts.map((p) => p.text).join(), text);
      final boundaries = {0};
      var offset = 0;
      for (final grapheme in text.characters) {
        offset += grapheme.length;
        boundaries.add(offset);
      }
      var next = 0;
      for (final part in parts) {
        expect(part.start.offset, next);
        expect(boundaries.contains(part.endOffset), isTrue);
        next = part.endOffset;
      }
      expect(parts.where((p) => p.indented), hasLength(1));
      for (final page in result.pages) {
        expect(page.height, lessThanOrEqualTo(480.01));
      }
    },
  );

  test('font, orientation and accessibility scale keep the content anchor', () {
    final blocks = [NovelBlock.text(List.filled(120, '字号变化也不能跳过这段文字。').join())];
    const anchor = NovelPosition(1, 770);
    for (final result in [
      layout(blocks),
      layout(blocks, fontSize: 32, scale: 1.5),
      layout(blocks, size: const Size(600, 200)),
    ]) {
      final page = result.pages[result.pageFor(anchor)];
      expect(
        page.fragments.any(
          (p) =>
              p.start.block == anchor.block &&
              p.start.offset <= anchor.offset &&
              p.endOffset > anchor.offset,
        ),
        isTrue,
      );
    }
  });

  test('illustrations occupy a whole page in the original chapter order', () {
    final result = layout(const [
      NovelBlock.text('前文'),
      NovelBlock.image('image'),
      NovelBlock.text('后文'),
    ]);
    final page = result.pages[result.pageFor(const NovelPosition(2))];
    expect(page.fragments, hasLength(1));
    expect(page.fragments.single.imageUrl, 'image');
    expect(
      result.pages.expand((p) => p.fragments).map((p) => p.start.block),
      orderedEquals([0, 1, 2, 3]),
    );
  });

  test(
    'empty chapters and a viewport smaller than one glyph still advance',
    () {
      expect(layout([]).pages, hasLength(1));
      final result = layout(const [
        NovelBlock.text('甲乙👩‍🚀'),
      ], size: const Size(12, 3));
      expect(
        result.pages
            .expand((p) => p.fragments)
            .where((p) => p.start.block == 1)
            .map((p) => p.text)
            .join(),
        '甲乙👩‍🚀',
      );
    },
  );

  testWidgets(
    'swipes, side taps and keyboard turn pages; center tap opens menu',
    (tester) async {
      tester.view.reset();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = settings();
      final watch = NovelWatch(
        blocks: [NovelBlock.text(List.filled(150, '每页都要正确记录阅读位置。').join())],
      );
      var position = const NovelPosition(0);
      var menuTaps = 0;
      Future<void> open({Size? size}) async {
        if (size != null) tester.view.physicalSize = size;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: NovelPagedView(
                key: const ValueKey('pager'),
                watch: watch,
                title: '第一章',
                settings: s,
                position: position,
                onPositionChanged: (value) => position = value,
                onCenterTap: () => menuTaps++,
                imageBuilder: (_) => const SizedBox(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await open();
      await tester.drag(find.byType(PageView), const Offset(-310, 0));
      await tester.pumpAndSettle();
      expect(
        position.offset,
        greaterThan(0),
        reason:
            'page=${tester.widget<PageView>(find.byType(PageView)).controller?.page}, block=${position.block}, counter=${tester.widget<Text>(find.byKey(const ValueKey('novel-page-counter'))).data}',
      );
      final firstOffset = position.offset;
      await tester.tapAt(const Offset(375, 300));
      await tester.pumpAndSettle();
      expect(position.offset, greaterThan(firstOffset));
      await tester.tapAt(const Offset(195, 300));
      await tester.pumpAndSettle();
      expect(menuTaps, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(position.offset, firstOffset);
      s.fontSize = 30;
      await open(size: const Size(844, 390));
      expect(
        position.offset,
        firstOffset,
        reason: 'reflow must not overwrite the content anchor',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('chapter boundary taps request the adjacent chapter', (
    tester,
  ) async {
    var previous = 0;
    var next = 0;
    final s = settings();
    Future<void> open(Key key) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NovelPagedView(
              key: key,
              watch: const NovelWatch(blocks: [NovelBlock.text('短章节')]),
              title: '章节',
              settings: s,
              position: const NovelPosition(0),
              onPositionChanged: (_) {},
              onCenterTap: () {},
              imageBuilder: (_) => const SizedBox(),
              onPreviousChapter: () => previous++,
              onNextChapter: () => next++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await open(const ValueKey(1));
    await tester.tapAt(const Offset(795, 300));
    await tester.pumpAndSettle();
    expect(next, 1);
    await open(const ValueKey(2));
    await tester.tapAt(const Offset(5, 300));
    await tester.pumpAndSettle();
    expect(previous, 1);
  });
}
