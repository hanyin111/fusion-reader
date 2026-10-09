import 'repository_fixture.dart';
// Live regression: a mobile UA on its own used to return only a short preview.
// Run: flutter test integration_test/linovelib_test.dart -d windows
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/services/extension_runtime.dart';
import 'package:fusion_reader/services/image_loader.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.root);
  final Directory root;
  Future<String> _dir(String name) async {
    final dir = Directory('${root.path}/$name');
    await dir.create(recursive: true);
    return dir.path;
  }

  @override
  Future<String?> getApplicationDocumentsPath() => _dir('documents');
  @override
  Future<String?> getApplicationSupportPath() => _dir('support');
  @override
  Future<String?> getTemporaryPath() => _dir('temp');
  @override
  Future<String?> getApplicationCachePath() => _dir('cache');
}

void isolateLinovelibTestStorage() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final root = Directory(
    Platform.environment['FUSION_VERIFY_ROOT'] ??
        Directory.systemTemp.createTempSync('fusion_linovelib_').path,
  );
  PathProviderPlatform.instance = _TestPaths(root);
}

void main() {
  isolateLinovelibTestStorage();

  testWidgets(
    'mobile browser loads complete text and chapter illustrations',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('正在验证哔哩轻小说正文加载'))),
        ),
      );
      await tester.runAsync(() async {
        await Storage.init();
        final script = await repositoryFixture('linovelib');
        final prelude = await rootBundle.loadString('assets/js/runtime.js');
        final service = ExtensionService(
          meta: ExtensionMeta.parse(script)!,
          script: script,
          prelude: prelude,
        );
        await service.init();
        try {
          final text = NovelWatch.fromJson(
            await service.watch('/novel/2139/76673.html'),
          );
          final chars = text.textLines.join().length;
          print('序章：$chars 字，${text.blocks.length} 块');
          expect(chars, greaterThan(550), reason: '仍然只有服务器返回的短预览');
          expect(
            text.textLines.join(),
            contains('下一秒，菜月昴死亡。'),
            reason: '序章末尾缺失',
          );
          expect(
            text.textLines.where((line) => line.contains('下一秒，菜月昴死亡。')).length,
            1,
            reason: '隐藏的重复段落被当作正文',
          );
          expect(
            text.textLines.join(),
            isNot(matches('內容加載失敗|内容加载失败|更换浏览器|更換瀏覽器')),
          );
          expect(text.headers['User-Agent'], contains('Mobile'));

          final longChapter = NovelWatch.fromJson(
            await service.watch('/novel/2139/76674.html'),
          );
          print(
            '第一章：${longChapter.textLines.join().length} 字，${longChapter.blocks.length} 块',
          );
          expect(
            longChapter.textLines.join().length,
            greaterThan(5000),
            reason: '长章节仍然被截断或没有合并分页',
          );
          expect(longChapter.textLines.join(), isNot(matches('內容加載失敗|内容加载失败')));

          final art = NovelWatch.fromJson(
            await service.watch(
              'https://www.linovelib.com/novel/2139/129550.html',
            ),
          );
          final illustrations = art.blocks.where((b) => b.isImage).toList();
          print('插图章：${illustrations.length} 张插图');
          expect(illustrations.length, greaterThan(1), reason: '站点仍未发出真正的插图');
          final bytes = await SourceImageCache.fetchBytes(
            'linovelib',
            illustrations.first.imageUrl,
            headers: art.headers,
          );
          print('首张插图：${bytes.length} 字节');
          expect(bytes.length, greaterThan(1000), reason: '插图无法实际下载');
        } finally {
          print('正在关闭扩展运行时');
          service.dispose();
          print('扩展运行时已关闭');
        }
      });
      await tester.pump();
      print('正文与插图验证完成');
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
