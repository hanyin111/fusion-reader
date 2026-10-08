import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/models/reader_settings.dart';
import 'package:fusion_reader/pages/detail_page.dart';
import 'package:fusion_reader/pages/history_page.dart';
import 'package:fusion_reader/pages/library_page.dart';
import 'package:fusion_reader/pages/novel_reader.dart';
import 'package:fusion_reader/services/local_library.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../test/history_test.dart' show novel, comic, progress;

class _TestPaths extends PathProviderPlatform {
  final String root;
  _TestPaths(this.root);
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform originalPaths;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('fusion_history_native_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(root.path);
    await Storage.init();
  });
  setUp(() async {
    await Storage.clearHistory();
    await Storage.favoritesBox.clear();
    await Storage.localBox.clear();
  });
  Future<void> settleHistory(WidgetTester tester) async {
    await tester.runAsync(() => Storage.historyBox.flush());
    await tester.pumpAndSettle();
  }

  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    await root.delete(recursive: true);
  });

  testWidgets('bundled serif renders differently from the platform fallback', (
    tester,
  ) async {
    final serifKey = GlobalKey();
    final fallbackKey = GlobalKey();
    Widget sample(GlobalKey key, String family) => RepaintBoundary(
      key: key,
      child: SizedBox(
        width: 380,
        height: 64,
        child: ColoredBox(
          color: Colors.white,
          child: Text(
            '阅读历史 永字八法 ABC 123',
            style: TextStyle(
              fontFamily: family,
              color: Colors.black,
              fontSize: 24,
              height: 1.4,
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              sample(serifKey, ReaderFont.byName('衬线').family!),
              sample(fallbackKey, 'FusionMissingFontForFallbackCheck'),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Future<Uint8List> pixels(GlobalKey key) async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        return (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    }

    await tester.runAsync(() async {
      expect(
        listEquals(await pixels(serifKey), await pixels(fallbackKey)),
        isFalse,
        reason: '衬线必须实际使用打包字体，不能回退到系统字体',
      );
    });
  });

  testWidgets(
    'unfavorited novel returns through shelf history with its reading position',
    (tester) async {
      late MediaItem item;
      late MediaEpisodeGroup group;
      await tester.runAsync(() async {
        final book = File(
          '${root.path}${Platform.pathSeparator}history-book.txt',
        );
        await book.writeAsString(
          '第1章 历史测试\n${List.generate(50, (i) => '这是第$i段，用于检查未收藏小说的历史记录和阅读位置。').join('\n')}',
        );
        item = await LocalLibrary.import(book.path, MediaType.novel);
        group = (await LocalLibrary.detail(item)).episodes.first;
        final settings = NovelReaderSettings.load()..resetToDefaults();
        settings.fontName = '衬线';
        await settings.save();
      });
      Future<void> settleReader() async {
        for (var i = 0; i < 8; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(
        MaterialApp(
          home: NovelReaderPage(
            item: item,
            group: group,
            groupIndex: 0,
            index: 0,
          ),
        ),
      );
      await settleReader();
      expect(find.textContaining('这是第0段'), findsOneWidget);
      final body = tester.widget<Text>(find.textContaining('这是第0段'));
      expect(body.style!.fontFamily, 'Noto Serif CJK SC');
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();
      await tester.runAsync(() async {
        final record = Storage.historyOf(item.key)!;
        expect(record.item!.title, item.title);
        await Storage.saveHistory(record.copyWith(position: 15));
      });
      expect(Storage.favorites(), isEmpty);

      await tester.pumpWidget(const MaterialApp(home: LibraryPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('历史记录'));
      await tester.pumpAndSettle();
      expect(find.byType(HistoryPage), findsOneWidget);
      await tester.tap(find.text(item.title));
      await settleReader();
      expect(find.byType(DetailPage), findsOneWidget);
      expect(
        Storage.historyOf(item.key)!.position,
        15,
        reason: '查看作品详情不能覆盖已保存的阅读位置',
      );
      await tester.tap(
        find.widgetWithText(FilledButton, '继续: ${group.urls.first.name}'),
      );
      await settleReader();
      expect(find.byType(NovelReaderPage), findsOneWidget);
      expect(Storage.historyOf(item.key)!.position, 15);
      expect(find.textContaining('这是第14段'), findsOneWidget);
      expect(Storage.favorites(), isEmpty);
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();
      await tester.runAsync(() => Storage.historyBox.flush());
    },
  );
  testWidgets(
    'history filters, removes with undo, and confirms clearing without removing favorites',
    (tester) async {
      await tester.runAsync(() async {
        final now = DateTime.now().millisecondsSinceEpoch;
        await Storage.saveHistory(progress(novel, now - 1000));
        await Storage.saveHistory(progress(comic, now));
        await Storage.toggleFavorite(novel);
      });
      await tester.pumpWidget(const MaterialApp(home: LibraryPage()));
      await tester.pumpAndSettle();
      expect(find.text('读到: 第二章'), findsOneWidget);
      await tester.tap(find.byTooltip('历史记录'));
      await tester.pumpAndSettle();
      expect(find.text(novel.title), findsOneWidget);
      expect(find.text(comic.title), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(comic.title)).dy,
        lessThan(tester.getTopLeft(find.text(novel.title)).dy),
      );

      await tester.tap(find.widgetWithText(ChoiceChip, '小说'));
      await tester.pumpAndSettle();
      expect(find.text(comic.title), findsNothing);
      await tester.tap(find.byTooltip('删除记录'));
      await settleHistory(tester);
      expect(find.text(novel.title), findsNothing);
      expect(find.text('还没有小说历史记录'), findsOneWidget);
      await tester.tap(find.text('撤销'));
      await settleHistory(tester);
      expect(find.text(novel.title), findsOneWidget);
      expect(Storage.historyOf(novel.key)!.position, 37);

      await tester.tap(find.byTooltip('清空历史记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(Storage.history(), hasLength(2));
      await tester.tap(find.byTooltip('清空历史记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空'));
      await settleHistory(tester);
      expect(Storage.history(), isEmpty);
      expect(Storage.isFavorite(novel.key), isTrue);
      expect(Storage.historyOf(novel.key), isNull);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text(novel.title), findsOneWidget);
      expect(find.text('读到: 第二章'), findsNothing);
    },
  );

  testWidgets(
    'legacy entries without an installed source remain visible and deletable',
    (tester) async {
      await tester.runAsync(
        () => Storage.saveHistory(progress(novel, 123, metadata: false)),
      );
      await tester.pumpWidget(const MaterialApp(home: HistoryPage()));
      await tester.pumpAndSettle();
      expect(find.text('旧阅读记录'), findsOneWidget);
      expect(find.text('读到：第二章'), findsOneWidget);
      await tester.tap(find.text('旧阅读记录'));
      await tester.pumpAndSettle();
      expect(find.text('请先安装这条记录对应的扩展，再打开作品'), findsOneWidget);
      expect(find.byTooltip('删除记录'), findsOneWidget);
    },
  );
}
