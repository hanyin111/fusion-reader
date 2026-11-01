import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/pages/video_player_page.dart';
import 'package:fusion_reader/services/extension_manager.dart';
import 'package:fusion_reader/services/network.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:fusion_reader/widgets/danmaku_overlay.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'linovelib_test.dart' show isolateLinovelibTestStorage;
import 'video_danmaku_test.dart' show nativeAction, pumpUi, pumpUntil;

const _headers = {'X-Test-Token': 'fixture', 'X-List': r'one,two\value'};

// Desktop integration test. FFmpeg generates small synthetic HLS encodings,
// including a separate audio rendition; no external site/content is accessed.
Future<void> _createHls(Directory root) async {
  for (final entry in {
    'high': '320x180',
    'low': '160x90',
    'audio': '',
  }.entries) {
    final folder = await Directory('${root.path}/${entry.key}').create();
    final audio = entry.key == 'audio';
    final result = await Process.run('ffmpeg', [
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      '-f',
      'lavfi',
      '-i',
      audio
          ? 'anullsrc=r=44100:cl=stereo'
          : 'color=c=0x624580:s=${entry.value}:r=10',
      '-t',
      '30',
      if (audio) ...[
        '-vn',
        '-c:a',
        'aac',
        '-b:a',
        '24k',
      ] else ...[
        '-an',
        '-c:v',
        'libx264',
        '-preset',
        'ultrafast',
        '-pix_fmt',
        'yuv420p',
        '-g',
        '20',
        '-sc_threshold',
        '0',
      ],
      '-hls_time',
      '30',
      '-hls_segment_type',
      'fmp4',
      '-hls_playlist_type',
      'vod',
      '${folder.path}/index.m3u8',
    ]);
    if (result.exitCode != 0) {
      throw StateError('Synthetic HLS: ${result.stderr}');
    }
    final manifest = File('${folder.path}/index.m3u8');
    final text = await manifest.readAsString();
    // Deliberately use root-relative URIs for both init and media segments.
    await manifest.writeAsString(
      text
          .split('\n')
          .map((line) {
            if (line.contains('URI="')) {
              return line.replaceFirst('URI="', 'URI="/${entry.key}/');
            }
            if (line.isNotEmpty && !line.startsWith('#')) {
              return '/${entry.key}/$line';
            }
            return line;
          })
          .join('\n'),
    );
  }
}

void main() {
  isolateLinovelibTestStorage();
  MediaKit.ensureInitialized();
  testWidgets(
    'HLS quality switches keep audio, position, rate, pause and fullscreen',
    (tester) async {
      late Directory root;
      late HttpServer server;
      final requests = <String>[];
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('fusion_hls_live_');
        await _createHls(root);
        await Storage.init();
        await ExtensionManager.instance.init();
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          requests.add(request.uri.path);
          if (_headers.entries.any(
            (entry) => request.headers.value(entry.key) != entry.value,
          )) {
            request.response.statusCode = 403;
          } else if (request.uri.path == '/master.m3u8') {
            request.response.write('''#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Main",DEFAULT=YES,AUTOSELECT=YES,URI="audio/index.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=300000,RESOLUTION=320x180,CODECS="avc1.42e01e,mp4a.40.2",AUDIO="audio"
high/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=100000,RESOLUTION=160x90,CODECS="avc1.42e01e,mp4a.40.2",AUDIO="audio"
low/index.m3u8
''');
          } else {
            final file = File.fromUri(
              root.uri.resolve(request.uri.path.substring(1)),
            );
            if (await file.exists()) {
              request.response.add(await file.readAsBytes());
            } else {
              request.response.statusCode = 404;
            }
          }
          await request.response.close();
        });
        await ExtensionManager.instance.installFromScript(
          '''// ==MiruExtension==
// @name Video quality fixture
// @version 1.0.0
// @package video_quality_fixture
// @type bangumi
// @network direct
// @webSite http://127.0.0.1:${server.port}
// ==/MiruExtension==
export default class extends Extension {
  async watch() { return {type:'hls', url:'http://127.0.0.1:${server.port}/master.m3u8',
    netMode:'direct', headers:${jsonEncode(_headers)}}; }
}
''',
        );
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          await server.close(force: true);
          Network.reload();
          await Hive.close();
          await root.delete(recursive: true);
        });
      });
      const item = MediaItem(
        package: 'video_quality_fixture',
        type: MediaType.anime,
        title: '画质测试',
        url: '/work',
        cover: '',
      );
      Widget page() => MaterialApp(
        home: VideoPlayerPage(
          item: item,
          group: const MediaEpisodeGroup(
            title: '测试',
            urls: [MediaEpisode(name: '本地视频', url: '/episode')],
          ),
          groupIndex: 0,
          index: 0,
        ),
      );
      await tester.pumpWidget(page());
      final state = tester.state<VideoState>(find.byType(Video));
      final player = state.widget.controller.player;
      final errors = <String>[];
      final subscription = player.stream.error.listen((error) {
        errors.add(error);
        debugPrint('Quality fixture player error: $error');
      });
      addTearDown(subscription.cancel);
      final messages = <String>[];
      final logs = player.stream.log.listen((log) {
        messages.add('${log.prefix}: ${log.text}');
        if (messages.length > 120) messages.removeAt(0);
      });
      addTearDown(logs.cancel);
      try {
        await pumpUntil(
          tester,
          () =>
              player.state.width == 320 &&
              player.state.duration.inSeconds >= 29,
          'initial HLS frame and duration',
        );
      } catch (_) {
        debugPrint('Quality fixture requests: $requests');
        for (final message in messages) {
          debugPrint('Quality MPV $message');
        }
        debugPrint('Quality fixture playlist: ${player.state.playlist}');
        debugPrint(
          'Quality fixture menu: ${tester.widget<PopupMenuButton<int>>(find.byType(PopupMenuButton<int>).first).enabled}',
        );
        debugPrint(
          'Quality fixture state: ${player.state.width}x${player.state.height}, duration=${player.state.duration}',
        );
        debugPrint(
          'Quality fixture UI: ${find.textContaining('播放失败').evaluate().map((element) => (element.widget as Text).data).toList()}',
        );
        rethrow;
      }
      expect(
        player.state.tracks.audio.where(
          (track) => track.id != 'auto' && track.id != 'no',
        ),
        isNotEmpty,
      );
      await nativeAction(tester, () => player.setRate(1.5), 'set speed');
      await nativeAction(
        tester,
        () => player.seek(const Duration(seconds: 12)),
        'seek before quality switch',
      );
      await nativeAction(tester, player.pause, 'pause before quality switch');
      await pumpUntil(
        tester,
        () => player.state.position.inSeconds >= 11,
        'settled seek',
      );
      final position = player.state.position;
      final danmaku = tester
          .widget<DanmakuOverlay>(find.byType(DanmakuOverlay))
          .display;
      await tester.tap(find.byTooltip('清晰度').first);
      await pumpUi(tester);
      await tester.tap(find.widgetWithText(PopupMenuItem<int>, '90P'));
      await pumpUntil(
        tester,
        () => player.state.width == 160 && player.state.rate == 1.5,
        'low quality frame with speed restored',
      );
      expect(player.state.playing, isFalse);
      expect(
        (player.state.position - position).inMilliseconds.abs(),
        lessThan(1500),
      );
      expect(
        identical(
          tester.widget<DanmakuOverlay>(find.byType(DanmakuOverlay)).display,
          danmaku,
        ),
        isTrue,
      );
      await nativeAction(tester, state.enterFullscreen, 'enter fullscreen');
      await pumpUi(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byType(Video).last));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.byTooltip('清晰度').last);
      await pumpUi(tester);
      await tester.tap(find.widgetWithText(PopupMenuItem<int>, '180P'));
      await pumpUntil(
        tester,
        () => player.state.width == 320 && player.state.rate == 1.5,
        'fullscreen quality switch',
      );
      expect(state.isFullscreen(), isTrue);
      expect(player.state.playing, isFalse);
      expect(
        (player.state.position - position).inMilliseconds.abs(),
        lessThan(1500),
      );
      expect(
        requests,
        containsAll([
          '/low/index.m3u8',
          '/audio/init.mp4',
          '/audio/index0.m4s',
        ]),
      );
      expect(errors, isEmpty);
      await nativeAction(tester, state.exitFullscreen, 'exit fullscreen');
      await mouse.removePointer();
      await pumpUi(tester);
      await nativeAction(
        tester,
        () => player.seek(const Duration(seconds: 17)),
        'seek before leaving video',
      );
      await pumpUntil(
        tester,
        () => player.state.position.inSeconds >= 16,
        'settled exit position',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpUntil(
        tester,
        () => (Storage.historyOf(item.key)?.position ?? 0) >= 16000,
        'final timestamp saved on exit',
      );
      expect(Storage.historyOf(item.key)!.position, lessThan(19000));
      await tester.pumpWidget(page());
      final resumed = tester
          .state<VideoState>(find.byType(Video))
          .widget
          .controller
          .player;
      await pumpUntil(
        tester,
        () =>
            resumed.state.width == 320 &&
            resumed.state.position.inSeconds >= 16,
        'resume saved timestamp after reopening',
      );
      expect(resumed.state.position.inSeconds, lessThan(20));
      await nativeAction(tester, resumed.pause, 'pause resumed video');
      await nativeAction(
        tester,
        () => resumed.seek(const Duration(milliseconds: 29900)),
        'seek to ending',
      );
      await nativeAction(tester, resumed.play, 'finish video');
      await pumpUntil(
        tester,
        () =>
            resumed.state.completed &&
            Storage.historyOf(item.key)?.position == 0,
        'completed video resets next resume to beginning',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpUi(tester);
      expect(Storage.historyOf(item.key)!.position, 0);
      expect(tester.takeException(), isNull);
      debugPrint(
        'Quality playback passed: two HLS encodings, audio, headers, seek, speed, pause, fullscreen, saved resume and completion',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
