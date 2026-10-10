import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/services/danmaku_clock.dart';
import 'package:fusion_reader/services/danmaku_timeline.dart';

void main() {
  test(
    'optional source preserves legacy watch results and validates endpoints',
    () {
      expect(AnimeWatch.fromJson({'url': 'file.mp4'}).danmaku, isNull);
      expect(DanmakuSource.fromJson({'url': 'file:///secret.xml'}), isNull);
      final watch = AnimeWatch.fromJson({
        'url': 'video.mp4',
        'danmaku': {
          'url': 'https://comments.example/v3/?id=episode-1',
          'headers': {'Referer': 'https://anime.example/'},
          'netMode': 'direct',
        },
      });
      expect(watch.danmaku!.format, 'dplayer');
      expect(watch.danmaku!.headers['Referer'], 'https://anime.example/');
      expect(watch.danmaku!.netMode, 'direct');
    },
  );

  test(
    'parses DPlayer modes, colors and fractional seconds, ignoring bad rows',
    () {
      final result = parseDanmaku(
        jsonEncode({
          'code': 0,
          'data': [
            [3.2, 2, 255, 'user', 'bottom'],
            [1.5, 0, 0xff0000, 'user', 'scroll'],
            [2, 1, 0x00ff00, 'user', 'top'],
            ['NaN', 0, 0, '', 'bad'],
            [-1, 0, 0, '', 'bad'],
            [0, 9, 0, '', 'unsupported'],
            [0],
            null,
          ],
        }),
        'dplayer',
      );
      expect(result.map((item) => item.time), [1.5, 2, 3.2]);
      expect(result.map((item) => item.mode), [
        DanmakuMode.scroll,
        DanmakuMode.top,
        DanmakuMode.bottom,
      ]);
      expect(result.map((item) => item.color), [0xff0000, 0x00ff00, 255]);
    },
  );

  test('XML decodes text safely and rejects special/script modes', () {
    final result = parseDanmaku('''<i>
      <d p="0.5,1,25,16777215,1,0,user,1">A &amp; B</d>
      <d p="1,5,25,255,1,0,user,2">top</d>
      <d p="2,4,25,0,1,0,user,3">bottom</d>
      <d p="0,7,25,0,1,0,user,4">special</d><d p="invalid">bad</d>
    </i>''', 'bilibili');
    expect(result.map((item) => item.text), ['A & B', 'top', 'bottom']);
    expect(result.map((item) => item.mode), [
      DanmakuMode.scroll,
      DanmakuMode.top,
      DanmakuMode.bottom,
    ]);
    expect(() => parseDanmaku('not XML', 'bilibili'), throwsFormatException);
    expect(() => parseDanmaku('{}', 'dplayer'), throwsFormatException);
    expect(
      () => parseDanmaku('{"code":1,"data":[]}', 'dplayer'),
      throwsFormatException,
    );
  });

  test('limits oversized comments without breaking emoji', () {
    final result = parseDanmaku([
      [0, 0, 0xffffff, '', List.filled(180, '😀').join()],
    ], 'dplayer');
    expect(result.single.text.runes.length, 120);
    expect(result.single.text.contains('\uFFFD'), isFalse);
  });

  test(
    'clock freezes while paused/buffering and follows seek and all rates',
    () {
      var elapsed = 0.0;
      final clock = DanmakuClock(() => elapsed)..playing(true);
      elapsed = 2;
      expect(clock.time, 2);
      clock.playing(false);
      elapsed = 10;
      expect(clock.time, 2);
      clock.position(30);
      expect(clock.time, 30);
      clock.rate(2);
      clock.playing(true);
      elapsed = 13;
      expect(clock.time, 36);
      clock.buffering(true);
      elapsed = 20;
      expect(clock.time, 36);
      clock.buffering(false);
      clock.rate(.5);
      elapsed = 24;
      expect(clock.time, 38);
      clock.position(1);
      expect(clock.time, 1);
    },
  );

  Size measure(DanmakuComment comment) => Size(comment.text.length * 12, 20);

  test('dense lanes skip excess comments and never overlap', () {
    final timeline = DanmakuTimeline([
      for (var i = 0; i < 20; i++) DanmakuComment(time: 0, text: 'comment $i'),
    ], measure);
    final active = timeline.at(1, width: 400, lanes: 3);
    expect(active.length, 3);
    expect(active.map((item) => item.lane).toSet().length, 3);
    expect(timeline.at(8, width: 400, lanes: 3), isEmpty);
  });

  test('faster long comments cannot catch a short predecessor', () {
    final timeline = DanmakuTimeline([
      const DanmakuComment(time: 0, text: 'a'),
      DanmakuComment(time: 1, text: List.filled(80, 'a').join()),
    ], measure);
    final active = timeline.at(1, width: 400, lanes: 1);
    expect(active.length, 1);
    expect(active.single.comment.text, 'a');
  });

  test('seeks rebuild the correct episode window in both directions', () {
    final timeline = DanmakuTimeline([
      const DanmakuComment(time: 0, text: 'opening'),
      const DanmakuComment(time: 100, text: 'later'),
    ], measure);
    expect(timeline.at(1, width: 400, lanes: 2).single.comment.text, 'opening');
    expect(timeline.at(101, width: 400, lanes: 2).single.comment.text, 'later');
    expect(timeline.at(1, width: 400, lanes: 2).single.comment.text, 'opening');
  });

  test('fixed top comments reserve scrolling lanes and bottom is capped', () {
    final timeline = DanmakuTimeline([
      const DanmakuComment(time: 0, text: 'top', mode: DanmakuMode.top),
      const DanmakuComment(time: .1, text: 'scroll'),
      for (var i = 0; i < 5; i++)
        DanmakuComment(time: .2, text: 'bottom $i', mode: DanmakuMode.bottom),
    ], measure);
    final active = timeline.at(1, width: 400, lanes: 4);
    expect(
      active.where((item) => item.comment.mode == DanmakuMode.bottom).length,
      2,
    );
    expect(active.first.lane, 0);
    expect(active.firstWhere((item) => item.comment.text == 'scroll').lane, 1);
  });
}
