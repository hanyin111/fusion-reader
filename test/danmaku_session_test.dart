import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/danmaku.dart';
import 'package:fusion_reader/services/danmaku_session.dart';

void main() {
  test(
    'covered playback does not request again; prefetch deduplicates overlaps',
    () async {
      final requests = <double>[];
      final session = DanmakuSession(
        load: (from, to, _) async {
          requests.add(from);
          return [const DanmakuComment(time: 160, text: '重叠弹幕')];
        },
        onChanged: (_, _, _) {},
      );
      await session.update(0);
      await session.update(100);
      expect(requests, [0]);
      await session.update(155);
      expect(requests, [0, 140]);
      expect(session.comments.length, 1);
      session.dispose();
    },
  );

  test(
    'seek during a request fetches the new position after completion',
    () async {
      final first = Completer<List<DanmakuComment>>();
      final requests = <double>[];
      final session = DanmakuSession(
        load: (from, to, _) {
          requests.add(from);
          return requests.length == 1 ? first.future : Future.value([]);
        },
        onChanged: (_, _, _) {},
      );
      final pending = session.update(0);
      await session.update(600);
      first.complete([]);
      await pending;
      await Future<void>.delayed(Duration.zero);
      expect(requests, [0, 585]);
      session.dispose();
    },
  );

  test(
    'late responses cannot replace a new episode or imported file',
    () async {
      final pending = Completer<List<DanmakuComment>>();
      var changes = 0;
      final session = DanmakuSession(
        load: (_, _, _) => pending.future,
        onChanged: (_, _, _) => changes++,
      );
      final request = session.update(0);
      session.dispose();
      pending.complete([const DanmakuComment(time: 1, text: '旧章节')]);
      await request;
      expect(changes, 1);
    },
  );

  test(
    'failed requests are paced; a manual retry is allowed immediately',
    () async {
      var requests = 0;
      final session = DanmakuSession(
        load: (_, _, _) async {
          requests++;
          throw Exception('offline');
        },
        onChanged: (_, _, _) {},
      );
      await session.update(0);
      for (var i = 1; i < 20; i++) {
        await session.update(i.toDouble());
      }
      expect(requests, 1);
      await session.update(20, force: true);
      expect(requests, 2);
      session.dispose();
    },
  );

  test(
    'window cache is bounded and revisiting an evicted range reloads it',
    () async {
      var requests = 0;
      final session = DanmakuSession(
        load: (from, to, _) async {
          requests++;
          return [DanmakuComment(time: from + 1, text: '$from')];
        },
        onChanged: (_, _, _) {},
      );
      for (var i = 0; i < 15; i++) {
        await session.update(i * 300.0);
      }
      expect(session.comments.length, 12);
      await session.update(0);
      expect(requests, 16);
      session.dispose();
    },
  );
}
