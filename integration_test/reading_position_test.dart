// Reproduces the reported bug: reopening a comic restarted at page one even
// though the position had been recorded.
//
// Driven through the real reader widget with a locally imported comic, so no
// network is involved and the assertion is on what the reader actually shows.
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/pages/manga_reader.dart';
import 'package:fusion_reader/services/local_library.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:integration_test/integration_test.dart';

/// Smallest valid PNG, tinted per page so they are distinguishable.
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

  testWidgets('comic reopens on the page it was left at', (tester) async {
    await Storage.init();

    final root = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}fusion_pos_test');
    if (root.existsSync()) root.deleteSync(recursive: true);
    final chapter = Directory('${root.path}${Platform.pathSeparator}Chapter1')
      ..createSync(recursive: true);
    const pageCount = 20;
    for (var i = 1; i <= pageCount; i++) {
      File('${chapter.path}${Platform.pathSeparator}'
              '${i.toString().padLeft(2, '0')}.png')
          .writeAsBytesSync(pngBytes(i));
    }

    late MediaItem item;
    late MediaEpisodeGroup group;
    await tester.runAsync(() async {
      item = await LocalLibrary.import(root.path, MediaType.manga);
      final detail = await LocalLibrary.detail(item);
      group = detail.episodes.first;
    });
    expect(group.urls, isNotEmpty);

    // Tearing the reader down is a separate step because closing it persists
    // the current page — the same thing that happens when a reader backs out.
    Future<void> closeReader() async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();
    }

    var openCount = 0;
    Future<void> openReader() async {
      // Pumping the same widget type at the same position reuses its State, so
      // a distinct key is needed for initState — and the resume logic — to run.
      openCount++;
      await tester.pumpWidget(MaterialApp(
        home: MangaReaderPage(
          key: ValueKey('reader-$openCount'),
          item: item,
          group: group,
          groupIndex: 0,
          index: 0,
        ),
      ));
      // watch() does real file I/O, which the widget test's fake clock will not
      // advance — runAsync lets those futures actually complete between pumps.
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 120)));
        await tester.pump();
      }
    }

    // Storage is a real on-disk box, so a previous run's progress would
    // otherwise leak in and make the "starts at page 1" step meaningless.
    await tester.runAsync(() => Storage.historyBox.delete(item.key));

    // --- first visit: starts at page 1 ---
    await Storage.setSetting('mangaWebtoon', true);
    await openReader();
    expect(find.text('1/$pageCount'), findsOneWidget,
        reason: '首次打开应从第 1 页开始');
    print('首次打开: 第 1 页');

    // --- read up to page 9 (index 8), then leave ---
    await closeReader();
    await tester.runAsync(() async {
      final existing = Storage.historyOf(item.key)!;
      await Storage.saveHistory(existing.copyWith(position: 8));
    });
    expect(Storage.historyOf(item.key)!.position, 8);
    print('记录进度: index 8（第 9 页）');

    // --- reopen: must resume, and must still be there after images settle ---
    await openReader();
    expect(find.text('9/$pageCount'), findsOneWidget,
        reason: '重新打开应恢复到第 9 页，而不是回到开头');
    print('重新打开: 第 9 页 ✓');

    // The original bug only showed itself a beat later, once the lazily loaded
    // images forced a relayout and the scroll snapped back to the top.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(find.text('9/$pageCount'), findsOneWidget,
        reason: '图片加载完成后位置被重置回开头');
    print('图片加载后仍在第 9 页 ✓');

    // --- paged mode must resume too ---
    await closeReader();
    await tester.runAsync(() async {
      await Storage.setSetting('mangaWebtoon', false);
      final existing = Storage.historyOf(item.key)!;
      await Storage.saveHistory(existing.copyWith(position: 8));
    });
    await openReader();
    expect(find.text('9/$pageCount'), findsOneWidget,
        reason: '翻页模式也应恢复到第 9 页');
    print('翻页模式: 第 9 页 ✓');

    await tester.runAsync(() async {
      await LocalLibrary.remove(root.path);
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });
  }, timeout: const Timeout(Duration(minutes: 5)));
}
