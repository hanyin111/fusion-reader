import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/services/video_progress.dart';

const _record = HistoryRecord(
  key: 'fixture|work',
  episodeUrl: '/episode-2',
  episodeName: '第二集',
  groupIndex: 0,
  episodeIndex: 1,
  position: 12500,
  timestamp: 1,
);

void main() {
  test('only the matching episode resumes, in milliseconds', () {
    expect(
      videoResumePosition(_record, '/episode-2'),
      const Duration(milliseconds: 12500),
    );
    expect(videoResumePosition(_record, '/episode-1'), Duration.zero);
    expect(videoResumePosition(null, '/episode-2'), Duration.zero);
    expect(
      videoResumePosition(_record.copyWith(position: -1), '/episode-2'),
      Duration.zero,
    );
  });

  test(
    'new episode keeps its resume position until a real timeline update',
    () async {
      final records = <HistoryRecord>[];
      final session = VideoProgressSession(
        record: _record,
        write: (record) async => records.add(record),
      );
      await session.save(force: true);
      expect(records.single.position, 12500);
      expect(HistoryRecord.fromJson(records.single.toJson()).position, 12500);
    },
  );

  test(
    'frequent position events write at most once per interval; exit flushes',
    () async {
      var now = DateTime(2026, 11, 1);
      final records = <HistoryRecord>[];
      final session = VideoProgressSession(
        record: _record,
        now: () => now,
        write: (record) async => records.add(record),
      );
      await session.save(force: true);
      for (var second = 1; second <= 12; second++) {
        now = now.add(const Duration(seconds: 1));
        session.update(Duration(seconds: second + 12));
        await session.save();
      }
      expect(records.map((record) => record.position), [12500, 17000, 22000]);
      await session.save(force: true);
      expect(records.last.position, 24000);
      await session.save(force: true);
      expect(records.length, 4);
    },
  );

  test(
    'seeking backwards including zero replaces the local timestamp',
    () async {
      final records = <HistoryRecord>[];
      final session = VideoProgressSession(
        record: _record,
        write: (record) async => records.add(record),
      );
      await session.save(force: true);
      session.update(const Duration(seconds: 3));
      await session.save(force: true);
      session.update(Duration.zero);
      await session.save(force: true);
      expect(records.map((record) => record.position), [12500, 3000, 0]);
    },
  );

  test(
    'an outstanding periodic write cannot overwrite the final timestamp',
    () async {
      final gate = Completer<void>();
      final records = <HistoryRecord>[];
      final session = VideoProgressSession(
        record: _record,
        write: (record) async {
          records.add(record);
          if (records.length == 1) await gate.future;
        },
      );
      final periodic = session.save();
      await Future<void>.delayed(Duration.zero);
      session.update(const Duration(seconds: 20));
      final finalSave = session.save(force: true);
      expect(records.length, 1);
      gate.complete();
      await Future.wait([periodic, finalSave]);
      expect(records.map((record) => record.position), [12500, 20000]);
    },
  );

  test('a failed write can retry without waiting for the throttle', () async {
    var attempts = 0;
    final session = VideoProgressSession(
      record: _record,
      write: (record) async {
        if (attempts++ == 0) throw StateError('temporary write failure');
      },
    );
    await expectLater(session.save(), throwsStateError);
    await session.save();
    expect(attempts, 2);
  });
}
