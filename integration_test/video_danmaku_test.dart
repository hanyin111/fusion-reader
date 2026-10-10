import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/pages/comments_page.dart';
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
    'fullscreen supports speed and work comments without disrupting playback',
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
// @comments work
// ==/MiruExtension==
export default class extends Extension {
  async watch(url) { return {type:'mp4', url:${jsonEncode(image.path)},
    danmaku:{url:'http://127.0.0.1:${server.port}/'+url,netMode:'direct'}}; }
  async comments(work, chapter, page, parent) {
    return {comments:[{id:parent?'reply':'root',username:'测试用户',
      text:parent?'测试评论回复':'测试作品评论',replyCount:parent?0:1}],hasMore:false};
  }
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
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      Future<void> showControls() async {
        await mouse.moveTo(Offset.zero);
        await mouse.moveTo(tester.getCenter(find.byType(Video).last));
        await tester.pump(const Duration(milliseconds: 350));
        // Touch controls on iOS appear on a tap instead of a mouse hover.
        if (find.byTooltip('播放速度').evaluate().isEmpty) {
          await tester.tap(find.byType(Video).last);
          await tester.pump(const Duration(milliseconds: 350));
        }
      }

      await showControls();
      await tester.tap(find.byTooltip('播放速度').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(PopupMenuItem<double>, '1.5x'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
      expect(state.widget.controller.player.state.rate, 1.5);
      expect(Storage.setting('playbackRate'), 1.5);
      expect(fullscreenState.isFullscreen(), isTrue);
      await showControls();
      expect(
        tester
            .widget<PopupMenuButton<double>>(
              find.byType(PopupMenuButton<double>).last,
            )
            .initialValue,
        1.5,
      );

      await showControls();
      await tester.tap(find.byTooltip('作品评论').last);
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CommentsPage), findsOneWidget);
      expect(find.text('以下为整部作品的评论，各章节共用。'), findsOneWidget);
      expect(find.text('测试作品评论'), findsOneWidget);
      expect(state.widget.controller.player.state.playing, isFalse);
      await tester.tap(find.text('查看回复（1）'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
      expect(find.text('测试评论回复'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(fullscreenState.isFullscreen(), isTrue);
      expect(state.widget.controller.player.state.playing, isFalse);

      // Opening comments pauses an active video and resumes it on return.
      await tester.runAsync(state.widget.controller.player.play);
      await tester.pump();
      await showControls();
      await tester.tap(find.byTooltip('作品评论').last);
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
      expect(state.widget.controller.player.state.playing, isFalse);
      await tester.pageBack();
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      expect(state.widget.controller.player.state.playing, isTrue);
      await tester.runAsync(state.widget.controller.player.pause);
      await tester.pumpAndSettle();
      await mouse.removePointer();
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
