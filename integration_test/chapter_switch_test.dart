// Moving to the next chapter must start at the top, even if the previous
// chapter was scrolled to the bottom.
//
// The list keeps its scroll position across a rebuild, and initialScrollIndex
// only applies when the list is first created — so without an explicit reset
// the new chapter opens wherever the old one was left.
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/models/reader_settings.dart';
import 'package:fusion_reader/pages/manga_reader.dart';
import 'package:fusion_reader/pages/novel_reader.dart';
import 'package:fusion_reader/services/local_library.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

Uint8List pngBytes(int seed) {
  const header = [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE,
    0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54,
    0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, 0x00,
    0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D, 0xB0,
    0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
  ];
  return Uint8List.fromList([...header, seed & 0xFF]);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)));
      await tester.pump();
    }
  }

  testWidgets('novel: next chapter starts at the top', (tester) async {
    await Storage.init();

    final root = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}fusion_switch_novel');
    if (root.existsSync()) root.deleteSync(recursive: true);
    root.createSync(recursive: true);

    // Two chapters, each long enough to scroll.
    final buffer = StringBuffer();
    for (final chapter in [1, 2]) {
      buffer.writeln('第$chapter章 测试');
      for (var i = 1; i <= 60; i++) {
        buffer.writeln('第$chapter章的第 $i 段正文，用来占据版面以便滚动。');
      }
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
      final fresh = NovelReaderSettings.load()..resetToDefaults();
      await fresh.save();
    });
    expect(group.urls.length, greaterThanOrEqualTo(2),
        reason: '需要至少两章才能测试切章');

    await tester.pumpWidget(MaterialApp(
      home: NovelReaderPage(
        item: item,
        group: group,
        groupIndex: 0,
        index: 0,
      ),
    ));
    await settle(tester);

    // Scroll the first chapter to its end.
    final listFinder = find.byType(ScrollablePositionedList);
    expect(listFinder, findsOneWidget);
    for (var i = 0; i < 12; i++) {
      await tester.drag(listFinder, const Offset(0, -600));
      await tester.pump();
    }
    await settle(tester, rounds: 3);

    var visible = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((d) => d.contains('段正文'))
        .toList();
    print('第一章滚动后屏幕首段: ${visible.isEmpty ? "(空)" : visible.first}');
    expect(visible.any((d) => d.contains('第 1 段')), isFalse,
        reason: '没有真正滚动下去，后续断言无意义');

    // Move to the next chapter.
    await tester.tap(find.text('下一章'));
    await settle(tester);

    visible = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((d) => d.contains('段正文'))
        .toList();
    print('切换到下一章后屏幕首段: ${visible.isEmpty ? "(空)" : visible.first}');
    expect(visible.any((d) => d.contains('第 1 段')), isTrue,
        reason: '下一章没有从头开始，屏幕上是: ${visible.take(2).toList()}');

    await tester.runAsync(() async {
      await LocalLibrary.remove(bookPath);
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('manga webtoon: next chapter starts at page one', (tester) async {
    await Storage.init();

    final root = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}fusion_switch_manga');
    if (root.existsSync()) root.deleteSync(recursive: true);
    for (final chapter in ['Chapter1', 'Chapter2']) {
      final dir = Directory('${root.path}${Platform.pathSeparator}$chapter')
        ..createSync(recursive: true);
      for (var i = 1; i <= 20; i++) {
        File('${dir.path}${Platform.pathSeparator}'
                '${i.toString().padLeft(2, '0')}.png')
            .writeAsBytesSync(pngBytes(i));
      }
    }

    late MediaItem item;
    late MediaEpisodeGroup group;
    await tester.runAsync(() async {
      item = await LocalLibrary.import(root.path, MediaType.manga);
      final detail = await LocalLibrary.detail(item);
      group = detail.episodes.first;
      await Storage.historyBox.delete(item.key);
      await Storage.setSetting('mangaWebtoon', true);
    });
    expect(group.urls.length, greaterThanOrEqualTo(2));

    await tester.pumpWidget(MaterialApp(
      home: MangaReaderPage(
        item: item,
        group: group,
        groupIndex: 0,
        index: 0,
      ),
    ));
    await settle(tester);
    expect(find.text('1/20'), findsOneWidget);

    for (var i = 0; i < 12; i++) {
      await tester.drag(find.byType(ScrollablePositionedList), const Offset(0, -600));
      await tester.pump();
    }
    await settle(tester, rounds: 3);
    expect(find.text('1/20'), findsNothing, reason: '没有真正滚动下去');
    print('第一章已滚动到中后段');

    await tester.tap(find.byTooltip('下一章'));
    await settle(tester);

    expect(find.text('1/20'), findsOneWidget,
        reason: '下一章没有回到第 1 页');
    print('切换到下一章后回到第 1 页 ✓');

    await tester.runAsync(() async {
      await LocalLibrary.remove(root.path);
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });
  }, timeout: const Timeout(Duration(minutes: 5)));
}
