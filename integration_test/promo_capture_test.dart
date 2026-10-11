// Native client captures for the local promotional page. All content is a
// placeholder; the production pages and bundled fonts are used unchanged.
// Run explicitly: flutter test integration_test/promo_capture_test.dart -d windows
import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/main.dart' show kFontFamily;
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/models/reader_settings.dart';
import 'package:fusion_reader/pages/home.dart';
import 'package:fusion_reader/pages/history_page.dart';
import 'package:fusion_reader/pages/library_transfer_page.dart';
import 'package:fusion_reader/pages/manga_reader.dart';
import 'package:fusion_reader/pages/novel_reader.dart';
import 'package:fusion_reader/pages/video_player_page.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:fusion_reader/widgets/danmaku_overlay.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'video_fixture.dart';

class _CapturePaths extends PathProviderPlatform {
  final String root;
  _CapturePaths(this.root);
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

Future<void> _placeholder(
  File file,
  String label,
  int variant, {
  bool comic = false,
}) async {
  const size = Size(600, 840);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final base = [
    const Color(0xFF745590),
    const Color(0xFFA18AAD),
    const Color(0xFF4F3B68),
  ][variant % 3];
  canvas.drawRect(Offset.zero & size, Paint()..color = base);
  if (comic) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFF2EDF7),
    );
    for (final rect in [
      const Rect.fromLTWH(26, 28, 548, 252),
      const Rect.fromLTWH(26, 298, 266, 350),
      const Rect.fromLTWH(308, 298, 266, 350),
    ]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(6)),
        Paint()..color = base.withValues(alpha: .24),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(6)),
        Paint()
          ..color = base
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
    }
    canvas.drawCircle(
      const Offset(165, 470),
      55,
      Paint()..color = base.withValues(alpha: .45),
    );
    canvas.drawCircle(
      const Offset(445, 160),
      58,
      Paint()..color = base.withValues(alpha: .45),
    );
  } else {
    canvas.drawCircle(
      const Offset(450, 565),
      210,
      Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: .09),
    );
    canvas.drawCircle(
      const Offset(120, 825),
      280,
      Paint()..color = const Color(0xFF241C33).withValues(alpha: .18),
    );
    canvas.drawLine(
      const Offset(58, 188),
      const Offset(220, 188),
      Paint()
        ..color = const Color(0xFFEEE3F7)
        ..strokeWidth = 3,
    );
  }
  void text(String value, double fontSize, Offset position, Color color) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: fontSize,
          fontWeight: FontWeight.w500,
          color: color,
          height: 1.4,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 500);
    painter.paint(canvas, position);
    painter.dispose();
  }

  text(
    label,
    comic ? 28 : 46,
    comic ? const Offset(40, 700) : const Offset(55, 64),
    comic ? const Color(0xFF624580) : const Color(0xFFF7F0FD),
  );
  text(
    'PLACEHOLDER',
    18,
    comic ? const Offset(40, 758) : const Offset(58, 216),
    comic ? const Color(0xFF947EA5) : const Color(0xFFD5C5E5),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(600, 840);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  await file.writeAsBytes(bytes!.buffer.asUint8List());
  image.dispose();
  picture.dispose();
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'capture original client pages with placeholder content',
    (tester) async {
      final base = Directory.current;
      final root = Directory('${base.path}/build/private/promo-capture-data')
        ..createSync(recursive: true);
      final output = Directory('${base.path}/website/screenshots')
        ..createSync(recursive: true);
      final originalPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _CapturePaths(root.path);
      MediaKit.ensureInitialized();
      final danmakuServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      danmakuServer.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'code': 0,
            'data': [
              [0.2, 1, 0xeed8ff, 'placeholder', '弹幕展示 · 占位内容'],
              [0.4, 0, 0xffffff, 'placeholder', '一起看，一起分享'],
              [0.7, 0, 0xeed8ff, 'placeholder', '这一段用来展示滚动弹幕'],
              [1.0, 0, 0xffffff, 'placeholder', '字号、透明度都可以调整'],
              [1.4, 0, 0xffffff, 'placeholder', '这是演示文字，不是作品内容'],
              [1.8, 0, 0xeed8ff, 'placeholder', '在这里留下你的观看感受'],
              [0.5, 2, 0xffffff, 'placeholder', '所有展示素材均为占位内容'],
            ],
          }),
        );
        await request.response.close();
      });
      await tester.runAsync(() async {
        await Storage.init();
        await Storage.favoritesBox.clear();
        await Storage.clearHistory();
        await Storage.settingsBox.clear();
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await binding.setSurfaceSize(null);
        await tester.runAsync(() => Hive.close());
        PathProviderPlatform.instance = originalPaths;
        await danmakuServer.close(force: true);
      });

      final items = <MediaItem>[];
      const types = [MediaType.novel, MediaType.manga, MediaType.anime];
      await tester.runAsync(() async {
        for (var i = 0; i < 12; i++) {
          final type = types[i % 3];
          final title =
              '演示${type.label} ${(i ~/ 3 + 1).toString().padLeft(2, '0')}';
          final cover = File('${root.path}/cover-$i.png');
          await _placeholder(cover, title, i);
          final item = MediaItem(
            package: '展示来源',
            type: type,
            title: title,
            url: 'placeholder/$i',
            cover: cover.path,
          );
          items.add(item);
          await Storage.toggleFavorite(item);
          await Storage.saveHistory(
            HistoryRecord(
              key: item.key,
              episodeUrl: 'chapter/$i',
              episodeName: type == MediaType.anime ? '第 03 集' : '第 12 章',
              groupIndex: 0,
              episodeIndex: 0,
              timestamp: 1700000000000 - i * 1000,
              position: 3,
            ),
            item: item,
          );
        }
        final novel = NovelReaderSettings.load()
          ..resetToDefaults()
          ..fontName = '衬线'
          ..themeName = '跟随应用'
          ..paged = true
          ..fontSize = 18
          ..lineHeight = 1.9;
        await novel.save();
        final manifests = Hive.box('offline_manifests');
        await manifests.put('展示来源|novel-preview', {
          'payload': {
            'title': '演示小说 01',
            'subtitle': '第十二章 · 正文展示',
            'content': List.generate(
              24,
              (i) =>
                  '这是一段用于展示阅读排版的占位文字。'
                  '你可以调整字体、字号和行间距，也可以在滚动与左右翻页之间切换。'
                  '此处仅用于呈现客户端的真实阅读界面，不包含任何作品正文。',
            ),
          },
        });
        final comic = File('${root.path}/comic-page.png');
        await _placeholder(comic, '漫画页面占位', 1, comic: true);
        await manifests.put('展示来源|comic-preview', {
          'payload': {
            'urls': [comic.path],
          },
        });
        final video = await createTestVideo(root);
        await manifests.put('展示来源|video-preview', {
          'payload': {
            'type': 'mp4',
            'url': video.path,
            'danmaku': {
              'format': 'dplayer',
              'url': 'http://127.0.0.1:${danmakuServer.port}/placeholder',
            },
          },
        });
      });

      final repaintKey = GlobalKey();
      Future<void> capture(
        String filename,
        Size size,
        Widget home, {
        Brightness brightness = Brightness.light,
        bool video = false,
      }) async {
        const only = String.fromEnvironment('PROMO_ONLY');
        if (only.isNotEmpty && only != filename) return;
        await tester.pumpWidget(const SizedBox.shrink());
        await binding.setSurfaceSize(size);
        final baseTheme = ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF6750A4),
            brightness: brightness,
          ),
          useMaterial3: true,
          fontFamily: kFontFamily,
        );
        final theme = baseTheme.copyWith(
          textTheme: baseTheme.textTheme.apply(fontFamily: kFontFamily),
          primaryTextTheme: baseTheme.primaryTextTheme.apply(
            fontFamily: kFontFamily,
          ),
        );
        await tester.pumpWidget(
          RepaintBoundary(
            key: repaintKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: theme,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(size: size, devicePixelRatio: 1),
                child: child!,
              ),
              home: home,
            ),
          ),
        );
        for (var i = 0; i < 12; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        if (video) {
          final player = tester
              .state<VideoState>(find.byType(Video))
              .widget
              .controller
              .player;
          for (var i = 0; i < 60 && player.state.width == null; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)),
            );
            await tester.pump(const Duration(milliseconds: 100));
          }
          for (var i = 0; i < 40; i++) {
            final overlay = tester.widget<DanmakuOverlay>(
              find.byType(DanmakuOverlay),
            );
            if (overlay.display.comments.isNotEmpty) break;
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)),
            );
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(
            tester
                .widget<DanmakuOverlay>(find.byType(DanmakuOverlay))
                .display
                .comments,
            hasLength(7),
          );
          await tester.runAsync(() => player.pause());
          await tester.runAsync(() => player.seek(const Duration(seconds: 3)));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 300)),
          );
          await tester.tapAt(tester.getCenter(find.byType(Video)));
          await tester.pump(const Duration(milliseconds: 300));
        }
        await tester.pump();
        await tester.runAsync(() async {
          final boundary =
              repaintKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '${output.path}/$filename.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          // ignore: avoid_print
          print('Captured $filename: ${image.width} x ${image.height}');
          image.dispose();
        });
        expect(tester.takeException(), isNull);
      }

      const phone = Size(390, 844),
          tablet = Size(1024, 768),
          desktop = Size(1280, 800);
      await capture('shelf-phone', phone, const HomeShell());
      await capture('shelf-tablet', tablet, const HomeShell());
      await capture('shelf-desktop', desktop, const HomeShell());
      final novelGroup = MediaEpisodeGroup(
        title: '章节',
        urls: const [MediaEpisode(name: '第十二章 · 正文展示', url: 'novel-preview')],
      );
      Widget novel() => NovelReaderPage(
        item: items[0],
        group: novelGroup,
        groupIndex: 0,
        index: 0,
      );
      await capture('novel-phone', phone, novel());
      await capture('novel-tablet', tablet, novel());
      await capture(
        'novel-phone-dark',
        phone,
        novel(),
        brightness: Brightness.dark,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        final settings = NovelReaderSettings.load()..fontSize = 22;
        await settings.save();
      });
      await capture('novel-phone-large', phone, novel());
      await capture(
        'novel-phone-dark-large',
        phone,
        novel(),
        brightness: Brightness.dark,
      );
      await capture(
        'comic-tablet',
        tablet,
        MangaReaderPage(
          item: items[1],
          group: MediaEpisodeGroup(
            title: '章节',
            urls: const [
              MediaEpisode(name: '第十二话 · 页面展示', url: 'comic-preview'),
            ],
          ),
          groupIndex: 0,
          index: 0,
        ),
      );
      await capture(
        'video-tablet',
        tablet,
        VideoPlayerPage(
          item: items[2],
          group: MediaEpisodeGroup(
            title: '剧集',
            urls: const [
              MediaEpisode(name: '第 03 集 · 视频占位', url: 'video-preview'),
            ],
          ),
          groupIndex: 0,
          index: 0,
        ),
        video: true,
      );
      await capture('transfer-phone', phone, const LibraryTransferPage());
      await capture('history-phone', phone, const HistoryPage());
      await tester.pumpWidget(const SizedBox.shrink());
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
