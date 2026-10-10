import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/services/cache_download_queue.dart';
import 'package:fusion_reader/widgets/cache_selection_dialog.dart';

const item = MediaItem(
  package: 'fixture',
  type: MediaType.novel,
  title: '测试小说',
  url: '/work',
);
const chapters = [
  MediaEpisode(name: '第一章', url: '/1'),
  MediaEpisode(name: '第二章', url: '/2'),
  MediaEpisode(name: '第三章', url: '/3'),
];

void main() {
  test(
    'batches from different pages continue serially and skip duplicates/cached chapters',
    () async {
      final first = Completer<void>();
      final seen = <String>[];
      var active = 0;
      var maximum = 0;
      final queue = CacheDownloadQueue(
        download: (task) async {
          active++;
          if (active > maximum) maximum = active;
          seen.add(task.episode.url);
          if (task.episode.url == '/1') await first.future;
          active--;
        },
        isCached: (_, episode) => episode.url == '/3',
        cancelDownload: (_) {},
      );
      addTearDown(queue.dispose);
      expect(queue.enqueueAll(item, chapters), 2);
      expect(queue.enqueueAll(item, chapters), 0);
      const other = MediaItem(
        package: 'fixture',
        type: MediaType.manga,
        title: '另一作品',
        url: '/other',
      );
      final last = queue.enqueue(
        other,
        const MediaEpisode(name: '漫画章节', url: '/4'),
      )!;
      expect(seen, ['/1']);
      first.complete();
      await last.finished;
      expect(seen, ['/1', '/2', '/4']);
      expect(maximum, 1);
      expect(queue.activeCount, 0);
      expect(
        queue.tasks.every((task) => task.state == CacheTaskState.completed),
        isTrue,
      );
    },
  );

  test(
    'cancel removes queued work and waits for active cleanup before retrying',
    () async {
      final running = Completer<void>();
      final seen = <String>[];
      final queue = CacheDownloadQueue(
        download: (task) async {
          seen.add(task.episode.url);
          await running.future;
        },
        isCached: (_, _) => false,
        cancelDownload: (_) => running.complete(),
      );
      addTearDown(queue.dispose);
      queue.enqueueAll(item, chapters);
      await queue.cancel('fixture|/2');
      expect(queue.taskOf('fixture|/2')!.state, CacheTaskState.cancelled);
      await queue.cancelAll();
      expect(seen, ['/1']);
      expect(queue.activeCount, 0);
      expect(
        queue.tasks.every((task) => task.state == CacheTaskState.cancelled),
        isTrue,
      );
      queue.retry('fixture|/2');
      await queue.taskOf('fixture|/2')!.finished;
      expect(seen, ['/1', '/2']);
      expect(queue.taskOf('fixture|/2')!.state, CacheTaskState.completed);
    },
  );

  test(
    'one failure is retained for retry and does not abort later chapters',
    () async {
      var failures = 1;
      final queue = CacheDownloadQueue(
        download: (task) async {
          if (task.episode.url == '/1' && failures-- > 0) {
            throw Exception('HTTP 403');
          }
        },
        isCached: (_, _) => false,
        cancelDownload: (_) {},
      );
      addTearDown(queue.dispose);
      queue.enqueueAll(item, chapters);
      await queue.taskOf('fixture|/3')!.finished;
      expect(queue.taskOf('fixture|/1')!.state, CacheTaskState.failed);
      expect(queue.taskOf('fixture|/1')!.error, contains('403'));
      expect(queue.taskOf('fixture|/3')!.state, CacheTaskState.completed);
      queue.retry('fixture|/1');
      await queue.taskOf('fixture|/1')!.finished;
      expect(queue.taskOf('fixture|/1')!.state, CacheTaskState.completed);
      queue.clearFinished();
      expect(queue.tasks, isEmpty);
    },
  );

  testWidgets(
    'range selection validates bounds and returns the inclusive selected chapters',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      List<MediaEpisode>? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showDialog<List<MediaEpisode>>(
                    context: context,
                    builder: (_) => const CacheSelectionDialog(
                      group: MediaEpisodeGroup(title: '第一卷', urls: chapters),
                      initialChapter: 2,
                    ),
                  );
                },
                child: const Text('选择章节'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('选择章节'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(1), '1');
      await tester.tap(find.text('加入缓存列表'));
      await tester.pumpAndSettle();
      expect(find.text('结束章节不能小于起始章节'), findsOneWidget);
      await tester.enterText(fields.at(1), '9');
      await tester.tap(find.text('加入缓存列表'));
      await tester.pumpAndSettle();
      expect(find.text('请输入 1–3'), findsOneWidget);
      await tester.enterText(fields.at(1), '3');
      await tester.tap(find.text('加入缓存列表'));
      await tester.pumpAndSettle();
      expect(result!.map((episode) => episode.url), ['/2', '/3']);
      expect(tester.takeException(), isNull);
    },
  );
}
