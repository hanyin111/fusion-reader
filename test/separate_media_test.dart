import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/services/danmaku_service.dart';
import 'package:fusion_reader/services/player_config.dart';
import 'package:fusion_reader/services/separate_media.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'separate track quoting preserves URLs containing delimiters and UTF-8',
    () {
      const video = 'https://video.example/file?x=1,2;片段';
      const audio = 'https://video.example/audio?key=%2C';
      final result = separateMediaPlaylist(video, audio);
      expect(result, contains('%${utf8.encode(video).length}%$video'));
      expect(result, contains('%${utf8.encode(audio).length}%$audio'));
      expect(result.split('!new_stream').length, 3);
    },
  );

  test(
    'alternate encodings retain audio only when specified or sharing the main URL',
    () {
      final watch = AnimeWatch.fromJson({
        'type': 'mp4',
        'url': 'https://video.example/high.m4s',
        'audioUrl': 'https://video.example/audio.m4s',
        'qualities': [
          {
            'label': '低',
            'url': 'https://video.example/low.m4s',
            'audioUrl': 'https://video.example/audio.m4s',
          },
        ],
      });
      expect(
        watch.withQuality(watch.qualities.single).audioUrl,
        watch.audioUrl,
      );
      expect(
        watch.withQuality(AnimeQuality(label: '同一流', url: watch.url)).audioUrl,
        watch.audioUrl,
      );
      expect(
        watch
            .withQuality(
              const AnimeQuality(
                label: '普通视频',
                url: 'https://video.example/other.mp4',
              ),
            )
            .audioUrl,
        isNull,
      );
      for (final invalid in [
        'file:///not-allowed',
        'https://user:pass@video.example/a',
        'javascript:bad',
      ]) {
        expect(
          () => AnimeWatch.fromJson({
            'url': 'https://video.example/video',
            'audioUrl': invalid,
          }),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'preparing separate streams does not fetch media and writes a local timeline',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'fusion_separate_',
      );
      try {
        const watch = AnimeWatch(
          type: 'mp4',
          url: 'https://video.example/v.m4s',
          audioUrl: 'https://video.example/a.m4s',
          headers: {'X-Test': 'fixture'},
        );
        final media = await buildMedia(
          'fixture',
          watch,
          playlistDirectory: directory,
        );
        expect(
          await File(media.uri).readAsString(),
          separateMediaPlaylist(watch.url, watch.audioUrl!),
        );
        expect(media.httpHeaders!['X-Test'], 'fixture');
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  const xml =
      '<?xml version="1.0" encoding="UTF-8"?><i><d p="1.5,1,25,16777215">原创弹幕 😀</d></i>';
  for (final kind in ['plain', 'gzip', 'zlib', 'raw']) {
    test('decodes $kind comment bytes without losing text or time', () {
      final raw = utf8.encode(xml);
      final bytes = switch (kind) {
        'gzip' => gzip.encode(raw),
        'zlib' => ZLibEncoder().convert(raw),
        'raw' => ZLibEncoder(raw: true).convert(raw),
        _ => raw,
      };
      final comments = parseDanmaku(
        decodeDanmakuBytes(bytes, 'bilibili', encoding: 'deflate'),
        'bilibili',
      );
      expect(comments.single.text, '原创弹幕 😀');
      expect(comments.single.time, 1.5);
    });
  }
  test('JSON still decodes and inflated replies obey size limits', () {
    const body = '{"code":0,"data":[[1,0,16777215,"","测试"]]}';
    expect(
      parseDanmaku(
        decodeDanmakuBytes(utf8.encode(body), 'dplayer'),
        'dplayer',
      ).single.text,
      '测试',
    );
    expect(
      () => decodeDanmakuBytes(
        ZLibEncoder().convert(utf8.encode(xml * 100)),
        'bilibili',
        limit: 128,
      ),
      throwsFormatException,
    );
    expect(
      () => decodeDanmakuBytes(utf8.encode(xml), 'bilibili', limit: 10),
      throwsFormatException,
    );
  });
}
