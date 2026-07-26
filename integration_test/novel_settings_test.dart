// Checks that novel reading preferences reach the rendered text, persist, and
// do not cost the reader their place when the text reflows.
//
// Reflow is the interesting part: changing font size or line height changes
// every paragraph's height, which is exactly what an offset-based scroll
// position cannot survive.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/models/reader_settings.dart';
import 'package:fusion_reader/pages/novel_reader.dart';
import 'package:fusion_reader/services/local_library.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('reading preferences apply, persist and keep the position',
      (tester) async {
    await Storage.init();

    // A plain-text book with numbered paragraphs, so positions are checkable.
    final root = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}fusion_novel_cfg');
    if (root.existsSync()) root.deleteSync(recursive: true);
    root.createSync(recursive: true);
    final buffer = StringBuffer('第1章 测试\n');
    for (var i = 1; i <= 60; i++) {
      buffer.writeln('这是第 $i 段的正文内容，用来占据版面以便滚动。');
    }
    final bookPath = '${root.path}${Platform.pathSeparator}book.txt';
    File(bookPath).writeAsStringSync(buffer.toString());

    late MediaItem item;
    late MediaEpisodeGroup group;
    await tester.runAsync(() async {
      item = await LocalLibrary.import(bookPath, MediaType.novel);
      final detail = await LocalLibrary.detail(item);
      group = detail.episodes.first;
      await Storage.historyBox.delete(item.key);
      // Start from a known configuration. save() must be awaited or the reader
      // can render before the reset has reached storage.
      final fresh = NovelReaderSettings.load()..resetToDefaults();
      await fresh.save();
    });

    var openCount = 0;
    Future<void> closeReader() async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();
    }

    Future<void> openReader() async {
      openCount++;
      await tester.pumpWidget(MaterialApp(
        home: NovelReaderPage(
          key: ValueKey('novel-$openCount'),
          item: item,
          group: group,
          groupIndex: 0,
          index: 0,
        ),
      ));
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 120)));
        await tester.pump();
      }
    }

    /// Style of a body paragraph currently on screen.
    TextStyle bodyStyle() {
      final texts = tester.widgetList<Text>(find.byType(Text));
      final paragraph = texts.firstWhere(
        (t) => (t.data ?? '').contains('段的正文内容'),
        orElse: () => throw StateError('页面上找不到正文段落'),
      );
      return paragraph.style!;
    }

    await openReader();

    // --- defaults reach the text ---
    var style = bodyStyle();
    print('默认: 字号=${style.fontSize} 行距=${style.height} 字体=${style.fontFamily}');
    expect(style.fontSize, 18.0);
    expect(style.height, 1.7);
    expect(style.fontFamily, 'HarmonyOS Sans SC');

    // --- first-line indent is on by default ---
    final indented = tester
        .widgetList<Text>(find.byType(Text))
        .where((t) => (t.data ?? '').contains('段的正文内容'))
        .first;
    expect(indented.data!.startsWith('　　'), isTrue, reason: '首行缩进未生效');
    print('首行缩进: 生效');

    // --- changing preferences reaches the rendered text ---
    await tester.runAsync(() async {
      final s = NovelReaderSettings.load()
        ..fontSize = 26
        ..lineHeight = 2.2
        ..letterSpacing = 1.5
        ..fontWeightIndex = 2
        ..indentFirstLine = false
        ..justify = true
        ..fontName = '衬线'
        ..themeName = '米黄'
        ..horizontalPadding = 40
        ..paragraphSpacing = 24;
      await s.save();
    });
    await closeReader();
    await openReader();

    style = bodyStyle();
    print('调整后: 字号=${style.fontSize} 行距=${style.height} '
        '字间距=${style.letterSpacing} 字重=${style.fontWeight} 字体=${style.fontFamily}');
    expect(style.fontSize, 26.0, reason: '字号未生效');
    expect(style.height, 2.2, reason: '行距未生效');
    expect(style.letterSpacing, 1.5, reason: '字间距未生效');
    expect(style.fontWeight, FontWeight.w700, reason: '字重未生效');
    expect(style.fontFamily, 'serif', reason: '字体未生效');

    final plain = tester
        .widgetList<Text>(find.byType(Text))
        .where((t) => (t.data ?? '').contains('段的正文内容'))
        .first;
    expect(plain.data!.startsWith('　　'), isFalse, reason: '关闭缩进后仍有缩进');

    // Background colour comes from the chosen theme, not the app theme.
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffold.backgroundColor, ReaderTheme.byName('米黄').background,
        reason: '背景主题未生效');
    print('背景主题: 米黄已生效');

    // Justification and padding are structural, so assert on the widgets.
    expect(plain.textAlign, TextAlign.justify, reason: '两端对齐未生效');
    print('两端对齐: 生效');

    // --- position survives a reflow ---
    // Close first: leaving a chapter persists the page being viewed, so
    // writing the position while the reader is still alive would be undone.
    await closeReader();
    await tester.runAsync(() async {
      final existing = Storage.historyOf(item.key)!;
      await Storage.saveHistory(existing.copyWith(position: 30));
    });
    await openReader();

    var onScreen = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((d) => d.contains('段的正文内容'))
        .toList();
    expect(onScreen.any((d) => d.contains('第 30 段')), isTrue,
        reason: '恢复失败，屏幕上是: ${onScreen.take(3).toList()}');
    print('恢复到第 30 段: ✓');

    // Now shrink the text: every paragraph's height changes underneath us.
    await tester.runAsync(() async {
      final s = NovelReaderSettings.load()
        ..fontSize = 13
        ..lineHeight = 1.2;
      await s.save();
    });
    await closeReader();
    await openReader();

    onScreen = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((d) => d.contains('段的正文内容'))
        .toList();
    expect(onScreen.any((d) => d.contains('第 30 段')), isTrue,
        reason: '排版变化后位置丢失，屏幕上是: ${onScreen.take(3).toList()}');
    print('字号行距大幅变化后仍在第 30 段: ✓');

    await tester.runAsync(() async {
      final restored = NovelReaderSettings.load()..resetToDefaults();
      await restored.save();
      await LocalLibrary.remove(bookPath);
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });
  }, timeout: const Timeout(Duration(minutes: 6)));
}
