import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/pages/explore_page.dart';
import 'package:fusion_reader/pages/extension_login_page.dart';
import 'package:fusion_reader/pages/video_player_page.dart';
import 'package:fusion_reader/services/extension_credentials.dart';
import 'package:fusion_reader/services/extension_manager.dart';
import 'package:fusion_reader/services/extension_runtime.dart';
import 'package:fusion_reader/services/network.dart';
import 'package:fusion_reader/services/offline_cache.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:fusion_reader/widgets/danmaku_overlay.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'linovelib_test.dart' show isolateLinovelibTestStorage;
import 'video_danmaku_test.dart' show nativeAction, pumpUi, pumpUntil;

Future<void> _createMedia(Directory root) async {
  for (final name in ['high', 'low', 'audio']) {
    final audio = name == 'audio';
    final result = await Process.run('ffmpeg', [
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      '-f',
      'lavfi',
      '-i',
      audio
          ? 'sine=frequency=440:sample_rate=44100'
          : 'color=c=0x624580:s=${name == 'high' ? '320x180' : '160x90'}:r=10',
      '-t',
      '30',
      if (audio) ...[
        '-vn',
        '-c:a',
        'aac',
        '-b:a',
        '32k',
      ] else ...[
        '-an',
        '-c:v',
        'libx264',
        '-preset',
        'ultrafast',
        '-pix_fmt',
        'yuv420p',
      ],
      '-movflags',
      '+faststart',
      '${root.path}/$name.mp4',
    ]);
    if (result.exitCode != 0) {
      throw StateError('Synthetic media: ${result.stderr}');
    }
  }
}

void main() {
  isolateLinovelibTestStorage();
  MediaKit.ensureInitialized();
  testWidgets(
    'native QR bridge, separate audio, quality change and offline cache',
    (tester) async {
      late Directory root;
      late HttpServer server;
      var available = true;
      final manager = ExtensionManager.instance;
      final requests = <String>[];
      FlutterSecureStorage.setMockInitialValues({});
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('fusion_separate_');
        await _createMedia(root);
        await Storage.init();
        await manager.init();
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          requests.add(request.uri.path);
          if (!available) {
            request.response.statusCode = 503;
          } else if (request.uri.path == '/login') {
            request.response.headers.add(
              'Set-Cookie',
              'fixture=confirmed; HttpOnly; Path=/',
            );
            request.response.headers.add(
              'Set-Cookie',
              'second=fixture; Path=/',
            );
            request.response.write('{"confirmed":true}');
          } else if (request.uri.path == '/danmaku.xml') {
            request.response.headers.set('Content-Encoding', 'deflate');
            request.response.add(
              zlib.encode(
                utf8.encode('<i><d p="0,1,25,16777215">原创测试弹幕</d></i>'),
              ),
            );
          } else if (request.headers.value('X-Fixture') != 'required') {
            request.response.statusCode = 403;
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
        final base = 'http://127.0.0.1:${server.port}';
        await manager.installFromScript('''// ==MiruExtension==
// @name Separate stream fixture
// @version 1.0.0
// @package separate_fixture
// @type bangumi
// @login qr
// @network direct
// @webSite $base
// ==/MiruExtension==
export default class extends Extension {
  async detail() { return {title:'原创测试视频', episodes:[{title:'测试',urls:[{name:'测试集',url:'/episode'}]}]}; }
  async latest() { if (!(await this.getCredential())) throw Error('请先登录'); return [{title:'测试收藏',url:'/work'}]; }
  async loginStatus() { return {loggedIn: !!(await this.getCredential()), username:'测试用户'}; }
  async beginLogin() { return {qrText:'$base/auth', expiresIn:60, pollInterval:2}; }
  async pollLogin() {
    const result = await this.request('/login', {responseMetadata:true});
    if (result.status !== 200 || !(result.headers['set-cookie'] || []).some(value => value.includes('fixture=confirmed'))) throw Error('metadata bridge');
    this.package = 'another_source';
    await this.setCredential('fixture-native-only');
    return {status:'success'};
  }
  async watch() { return {type:'mp4',url:'$base/high.mp4',audioUrl:'$base/audio.mp4',netMode:'direct',
    headers:{'X-Fixture':'required'}, qualities:[
      {label:'高画质',url:'$base/high.mp4',audioUrl:'$base/audio.mp4'},
      {label:'低画质',url:'$base/low.mp4',audioUrl:'$base/audio.mp4'}],
    danmaku:{url:'$base/danmaku.xml',format:'bilibili',netMode:'direct'}}; }
}
''');
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await server.close(force: true);
          Network.reload();
          await Hive.close();
          await root.delete(recursive: true);
        });
      });
      late ExtensionService service;
      await tester.runAsync(() async {
        service = await manager.ensureLoaded('separate_fixture');
      });
      await tester.pumpWidget(const MaterialApp(home: ExplorePage()));
      await tester.tap(find.text('动画'));
      await pumpUntil(
        tester,
        () => find.text('来源登录').evaluate().isNotEmpty,
        'discovery login entry',
      );
      await tester.tap(find.text('来源登录'));
      await pumpUntil(
        tester,
        () => find.byType(QrImageView).evaluate().isNotEmpty,
        'native QR generation',
      );
      await pumpUntil(
        tester,
        () => find.byType(ExtensionLoginPage).evaluate().isEmpty,
        'native QR confirmation and protected write',
      );
      await pumpUntil(
        tester,
        () => find.text('测试收藏').evaluate().isNotEmpty,
        'discovery automatically refreshes after login',
      );
      await tester.runAsync(() async {
        expect(
          await ExtensionCredentials.instance.read('separate_fixture'),
          'fixture-native-only',
        );
        expect(
          await ExtensionCredentials.instance.read('another_source'),
          isNull,
        );
        expect((await service.loginStatus()).loggedIn, isTrue);
      });
      const item = MediaItem(
        package: 'separate_fixture',
        type: MediaType.anime,
        title: '原创测试视频',
        url: '/work',
        cover: '',
      );
      const episode = MediaEpisode(name: '测试集', url: '/episode');
      Widget page() => const MaterialApp(
        home: VideoPlayerPage(
          item: item,
          group: MediaEpisodeGroup(title: '测试', urls: [episode]),
          groupIndex: 0,
          index: 0,
        ),
      );
      await tester.pumpWidget(page());
      final player = tester
          .state<VideoState>(find.byType(Video))
          .widget
          .controller
          .player;
      final errors = <String>[];
      final subscription = player.stream.error.listen(errors.add);
      addTearDown(subscription.cancel);
      await pumpUntil(
        tester,
        () =>
            player.state.width == 320 && player.state.duration.inSeconds >= 29,
        'separate audio and video open',
      );
      expect(
        player.state.tracks.audio.where(
          (track) => track.id != 'auto' && track.id != 'no',
        ),
        isNotEmpty,
      );
      await pumpUntil(
        tester,
        () => tester
            .widget<DanmakuOverlay>(find.byType(DanmakuOverlay))
            .display
            .comments
            .isNotEmpty,
        'compressed XML danmaku',
      );
      await nativeAction(
        tester,
        () => player.seek(const Duration(seconds: 12)),
        'seek split streams',
      );
      await nativeAction(tester, player.pause, 'pause split streams');
      await nativeAction(
        tester,
        () => player.setRate(1.5),
        'speed split streams',
      );
      await pumpUntil(
        tester,
        () => player.state.position.inSeconds >= 11,
        'settled split seek',
      );
      await tester.tap(find.byTooltip('清晰度').first);
      await pumpUi(tester);
      await tester.tap(find.widgetWithText(PopupMenuItem<int>, '低画质'));
      await pumpUntil(
        tester,
        () => player.state.width == 160,
        'switch split-stream quality',
      );
      expect(player.state.position.inSeconds, inInclusiveRange(11, 14));
      expect(player.state.playing, isFalse);
      expect(player.state.rate, 1.5);
      expect(
        player.state.tracks.audio.where(
          (track) => track.id != 'auto' && track.id != 'no',
        ),
        isNotEmpty,
      );
      expect(
        requests,
        containsAll(['/high.mp4', '/low.mp4', '/audio.mp4', '/danmaku.xml']),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => OfflineCache.instance.download(item, episode),
      );
      expect(OfflineCache.read(item.package, episode.url), isNotNull);
      available = false;
      final count = requests.length;
      await tester.pumpWidget(page());
      final offline = tester
          .state<VideoState>(find.byType(Video))
          .widget
          .controller
          .player;
      await pumpUntil(
        tester,
        () =>
            offline.state.width == 320 &&
            offline.state.duration.inSeconds >= 29,
        'offline separate audio and video',
      );
      expect(
        offline.state.tracks.audio.where(
          (track) => track.id != 'auto' && track.id != 'no',
        ),
        isNotEmpty,
      );
      expect(requests.length, count);
      expect(errors, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await manager.uninstall('separate_fixture');
        expect(
          await ExtensionCredentials.instance.read('separate_fixture'),
          isNull,
        );
      });
    },
  );
}
