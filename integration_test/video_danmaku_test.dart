import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
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
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'linovelib_test.dart' show isolateLinovelibTestStorage;
import 'video_fixture.dart';

// Native video and the danmaku ticker can keep scheduling frames. Wait for
// actual state, not for all animations to stop as pumpAndSettle would do.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() ready,
  String step, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  debugPrint('Video regression: $step');
  final deadline = DateTime.now().add(timeout);
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TestFailure('Timed out waiting for $step');
    }
    await pumpUi(tester);
  }
  // The target can appear before its route animation has finished.
  await pumpUi(tester);
}

Future<void> pumpUi(WidgetTester tester) async {
  // Start newly mounted route tickers before advancing their animation.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pump();
}

Future<void> nativeAction(
  WidgetTester tester,
  Future<void> Function() action,
  String step,
) async {
  debugPrint('Video regression: $step');
  await tester.runAsync(
    () => action().timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw TestFailure('Native action timed out: $step'),
    ),
  );
  await tester.pump();
}

bool onSettledRoute(Finder finder) {
  final elements = finder.evaluate();
  if (elements.isEmpty) return false;
  final route = ModalRoute.of(elements.last);
  return route?.isCurrent == true &&
      route?.animation?.status == AnimationStatus.completed &&
      route?.secondaryAnimation?.status == AnimationStatus.dismissed;
}

void main() {
  isolateLinovelibTestStorage();
  MediaKit.ensureInitialized();
  for (final platform in {defaultTargetPlatform, TargetPlatform.iOS}) {
    testWidgets(
      'fullscreen supports speed and work comments without disrupting playback ($platform)',
      (tester) async {
        late HttpServer server;
        final manager = ExtensionManager.instance;
        await tester.runAsync(() async {
          await Storage.init();
          await manager.init();
          final dir = await Directory.systemTemp.createTemp(
            'fusion_danmaku_video_',
          );
          final video = await createTestVideo(dir);
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
  async watch(url) { return {type:'mp4', url:${jsonEncode(video.path)},
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
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            await server.close(force: true);
            Network.reload();
            await Hive.close();
          });
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: VideoPlayerPage(
              item: item,
              group: group,
              groupIndex: 0,
              index: 0,
            ),
          ),
        );
        final state = tester.state<VideoState>(find.byType(Video));
        final player = state.widget.controller.player;
        await pumpUntil(tester, () {
          final overlays = find.byType(DanmakuOverlay).evaluate();
          return player.state.width == 160 &&
              player.state.height == 90 &&
              player.state.duration >= const Duration(seconds: 59) &&
              overlays.any(
                (element) =>
                    (element.widget as DanmakuOverlay)
                        .display
                        .comments
                        .length ==
                    3,
              );
        }, 'first video frame and three online comments');
        expect(find.textContaining('播放失败'), findsNothing);
        expect(find.byType(DanmakuOverlay), findsOneWidget);
        await nativeAction(
          tester,
          player.pause,
          'pause before opening settings',
        );
        await tester.tap(find.byTooltip('弹幕设置').first);
        await pumpUi(tester);
        expect(find.text('已加载 3 条弹幕'), findsOneWidget);
        await tester.tap(find.byType(Switch).first);
        await pumpUi(tester);
        expect(Storage.setting('danmakuEnabled'), isFalse);
        await tester.tap(find.byType(Switch).first);
        await pumpUi(tester);
        Navigator.of(tester.element(find.byType(Switch).first)).pop();
        await pumpUi(tester);

        await nativeAction(tester, state.enterFullscreen, 'enter fullscreen');
        await pumpUi(tester);
        expect(state.isFullscreen(), isTrue);
        expect(find.byType(DanmakuOverlay), findsWidgets);
        final fullscreenState = tester.state<VideoState>(
          find.byType(Video).last,
        );
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        Future<void> showControls() async {
          await mouse.moveTo(Offset.zero);
          await mouse.moveTo(tester.getCenter(find.byType(Video).last));
          await tester.pump(const Duration(milliseconds: 350));
          // Touch controls on iOS appear on a tap instead of a mouse hover.
          if (find.byTooltip('播放速度').hitTestable().evaluate().isEmpty) {
            await tester.tap(find.byType(Video).last);
            await tester.pump(const Duration(milliseconds: 350));
          }
        }

        await showControls();
        await tester.tap(find.byTooltip('播放速度').last);
        await pumpUi(tester);
        await tester.tap(find.widgetWithText(PopupMenuItem<double>, '1.5x'));
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await pumpUi(tester);
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
        await pumpUntil(
          tester,
          () => onSettledRoute(find.text('测试作品评论')),
          'work comments in fullscreen',
        );
        expect(find.byType(CommentsPage), findsOneWidget);
        expect(find.text('以下为整部作品的评论，各章节共用。'), findsOneWidget);
        expect(find.text('测试作品评论'), findsOneWidget);
        expect(state.widget.controller.player.state.playing, isFalse);
        await tester.tap(find.text('查看回复（1）'));
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await pumpUntil(
          tester,
          () => onSettledRoute(find.text('测试评论回复')),
          'comment replies',
        );
        expect(find.text('测试评论回复'), findsOneWidget);
        await tester.pageBack();
        await pumpUntil(
          tester,
          () => onSettledRoute(find.text('测试作品评论')),
          'return from replies to work comments',
        );
        await tester.pageBack();
        await pumpUntil(
          tester,
          () => onSettledRoute(find.byType(Video)),
          'return from comments to fullscreen',
        );
        expect(fullscreenState.isFullscreen(), isTrue);
        expect(state.widget.controller.player.state.playing, isFalse);

        // Opening comments pauses an active video and resumes it on return.
        await nativeAction(tester, player.play, 'resume video');
        await showControls();
        await tester.tap(find.byTooltip('作品评论').last);
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await pumpUntil(
          tester,
          () => onSettledRoute(find.text('测试作品评论')),
          'comments pause an active video',
        );
        expect(state.widget.controller.player.state.playing, isFalse);
        await tester.pageBack();
        await pumpUntil(
          tester,
          () => onSettledRoute(find.byType(Video)) && player.state.playing,
          'restore fullscreen and active playback',
        );
        expect(state.widget.controller.player.state.playing, isTrue);
        await nativeAction(tester, player.pause, 'pause after returning');
        await pumpUi(tester);
        await mouse.removePointer();
        await nativeAction(
          tester,
          fullscreenState.exitFullscreen,
          'exit fullscreen',
        );
        await pumpUi(tester);

        await tester.tap(find.byTooltip('下一集').first);
        await pumpUntil(
          tester,
          () => find
              .byType(DanmakuOverlay)
              .evaluate()
              .any(
                (element) =>
                    (element.widget as DanmakuOverlay).display.message
                        ?.contains('弹幕加载失败') ==
                    true,
              ),
          'failed comment endpoint without interrupting video',
        );
        expect(find.textContaining('播放失败'), findsNothing);
        await nativeAction(tester, player.pause, 'pause the next episode');
        await tester.tap(find.byTooltip('弹幕设置').first);
        await pumpUi(tester);
        expect(find.textContaining('弹幕加载失败'), findsOneWidget);
        expect(find.text('已加载 3 条弹幕'), findsNothing);
        expect(tester.takeException(), isNull);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
