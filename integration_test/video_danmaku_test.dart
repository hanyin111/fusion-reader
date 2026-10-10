import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/pages/video_player_page.dart';
import 'package:fusion_reader/services/extension_manager.dart';
import 'package:fusion_reader/services/network.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:fusion_reader/widgets/danmaku_overlay.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:image/image.dart' as img;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'linovelib_test.dart' show isolateLinovelibTestStorage;

void main() {
  isolateLinovelibTestStorage();
  MediaKit.ensureInitialized();
  testWidgets(
    'native video has danmaku in fullscreen and survives comment failures',
    (tester) async {
      late HttpServer server;
      final manager = ExtensionManager.instance;
      await tester.runAsync(() async {
        await Storage.init();
        await manager.init();
        final dir = await Directory.systemTemp.createTemp(
          'fusion_danmaku_video_',
        );
        final image = File('${dir.path}/frame.png');
        await image.writeAsBytes(
          img.encodePng(img.Image(width: 320, height: 180)),
        );
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          if (request.uri.path == '/missing') {
            request.response.statusCode = 404;
          } else {
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode({
                'code': 0,
                'data': [
                  [0, 1, 0xffffff, '', '测试顶部弹幕'],
                  [.2, 2, 0xffaaff, '', '测试底部弹幕'],
                  [1, 0, 0xffffff, '', '测试滚动弹幕'],
                ],
              }),
            );
          }
          await request.response.close();
        });
        await manager.installFromScript('''// ==MiruExtension==
// @name 弹幕测试
// @version 1.0.0
// @package video_danmaku_test
// @type bangumi
// @webSite http://127.0.0.1:${server.port}
// ==/MiruExtension==
export default class extends Extension {
  async watch(url) { return {type:'mp4', url:${jsonEncode(image.path)},
    danmaku:{url:'http://127.0.0.1:${server.port}/'+url,netMode:'direct'}}; }
}
''');
      });
      final item = MediaItem(
        package: 'video_danmaku_test',
        type: MediaType.anime,
        title: '弹幕验证',
        url: '/work',
        cover: '',
      );
      final group = MediaEpisodeGroup(
        title: '测试',
        urls: [
          const MediaEpisode(name: '有弹幕', url: 'comments'),
          const MediaEpisode(name: '接口失败', url: 'missing'),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: VideoPlayerPage(
            item: item,
            group: group,
            groupIndex: 0,
            index: 0,
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 3)),
      );
      await tester.pump();
      expect(find.textContaining('播放失败'), findsNothing);
      expect(find.byType(DanmakuOverlay), findsOneWidget);
      final state = tester.state<VideoState>(find.byType(Video));
      await tester.runAsync(state.widget.controller.player.pause);
      await tester.pump();
      await tester.tap(find.byTooltip('弹幕设置').first);
      await tester.pumpAndSettle();
      expect(find.text('已加载 3 条弹幕'), findsOneWidget);
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(Storage.setting('danmakuEnabled'), isFalse);
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(Switch).first)).pop();
      await tester.pumpAndSettle();

      await tester.runAsync(state.enterFullscreen);
      await tester.pumpAndSettle();
      expect(state.isFullscreen(), isTrue);
      expect(find.byType(DanmakuOverlay), findsWidgets);
      final fullscreenState = tester.state<VideoState>(find.byType(Video).last);
      await tester.runAsync(fullscreenState.exitFullscreen);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('下一集').first);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 2)),
      );
      await tester.pump();
      expect(find.textContaining('播放失败'), findsNothing);
      await tester.runAsync(state.widget.controller.player.pause);
      await tester.pump();
      await tester.tap(find.byTooltip('弹幕设置').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('弹幕加载失败'), findsOneWidget);
      expect(find.text('已加载 3 条弹幕'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await server.close(force: true);
        Network.reload();
        await Hive.close();
      });
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
