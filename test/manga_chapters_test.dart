import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/services/manga_chapters.dart';

MangaWatch chapter(int count, [String header = 'one']) => MangaWatch(
  urls: List.generate(count, (i) => '$header/$i'),
  headers: {'Referer': header},
);

void main() {
  test(
    'prefetch is lazy, coalesces requests and preserves earlier locations',
    () async {
      final pending = Completer<MangaWatch>();
      final requested = <int>[];
      final chapters = MangaChapters(
        initialIndex: 2,
        initialWatch: chapter(8),
        episodeCount: 5,
        load: (index) {
          requested.add(index);
          return pending.future;
        },
      );
      addTearDown(chapters.dispose);
      chapters.prefetch(0);
      expect(requested, isEmpty);
      chapters.prefetch(5);
      chapters.prefetch(7);
      expect(requested, [3]);
      pending.complete(chapter(4, 'two'));
      await Future<void>.delayed(Duration.zero);
      expect(chapters.pageCount, 12);
      expect(chapters.locate(7)!.chapter.index, 2);
      expect(chapters.locate(7)!.page, 7);
      expect(chapters.locate(8)!.chapter.index, 3);
      expect(chapters.locate(8)!.page, 0);
      expect(chapters.locate(8)!.chapter.watch.headers['Referer'], 'two');
      expect(chapters.globalPage(3, 2), 10);
      chapters.prefetch(7); // Still viewing the previous chapter.
      expect(requested, [3]);
    },
  );

  test(
    'failed or empty chapters retain content, require retry, and stop at the end',
    () async {
      var attempts = 0;
      final chapters = MangaChapters(
        initialIndex: 0,
        initialWatch: chapter(3),
        episodeCount: 2,
        load: (_) async {
          attempts++;
          if (attempts == 1) throw StateError('offline');
          return chapter(attempts == 2 ? 0 : 2);
        },
      );
      addTearDown(chapters.dispose);
      await chapters.loadNext();
      expect(chapters.error, isNotNull);
      chapters.prefetch(2);
      expect(attempts, 1);
      await chapters.loadNext();
      expect(chapters.error, isNotNull);
      expect(chapters.pageCount, 3);
      await chapters.loadNext();
      expect(chapters.pageCount, 5);
      expect(chapters.error, isNull);
      expect(chapters.hasNext, isFalse);
      await chapters.loadNext();
      expect(attempts, 3);
      expect(chapters.locate(5), isNull);
    },
  );

  test('leaving or replacing a strip ignores late responses', () async {
    final pending = Completer<MangaWatch>();
    final chapters = MangaChapters(
      initialIndex: 0,
      initialWatch: chapter(2),
      episodeCount: 3,
      load: (_) => pending.future,
    );
    var notifications = 0;
    chapters.addListener(() => notifications++);
    final task = chapters.loadNext();
    chapters.dispose();
    pending.complete(chapter(4));
    await task;
    expect(notifications, 1);
    expect(chapters.pageCount, 2);
  });

  test('a hanging request releases the retry control', () async {
    final chapters = MangaChapters(
      initialIndex: 0,
      initialWatch: chapter(2),
      episodeCount: 2,
      timeout: const Duration(milliseconds: 5),
      load: (_) => Completer<MangaWatch>().future,
    );
    addTearDown(chapters.dispose);
    await chapters.loadNext();
    expect(chapters.loading, isFalse);
    expect(chapters.error, isA<TimeoutException>());
    expect(chapters.pageCount, 2);
  });
}
