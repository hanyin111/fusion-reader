// Exercises the shared htmlToBlocks helper inside the real QuickJS runtime.
//
// Illustration handling used to depend on CSS selector groups and a plain
// `src`, which is why artwork went missing on sites that lazy-load images.
// These cases are deterministic, so they are checked without the network.
// ignore_for_file: avoid_print
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/services/extension_runtime.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:integration_test/integration_test.dart';

const probeScript = '''
// ==MiruExtension==
// @name         Blocks Probe
// @version      v1.0.0
// @author       test
// @lang         all
// @package      blocksprobe
// @type         fikushon
// @webSite      https://example.com
// ==/MiruExtension==

export default class extends Extension {
  async watch(html) {
    return { content: this.htmlToBlocks(html, 'https://example.com/novel/1/') };
  }
}
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('htmlToBlocks keeps artwork in place across markup styles',
      (tester) async {
    await tester.runAsync(() async {
      await Storage.init();
      final prelude = await rootBundle.loadString('assets/js/runtime.js');
      final meta = ExtensionMeta.parse(probeScript)!;
      final service =
          ExtensionService(meta: meta, script: probeScript, prelude: prelude);
      await service.init();

      Future<NovelWatch> run(String html) async =>
          NovelWatch.fromJson(await service.watch(html));

      // 1. Ordering: text, image, text.
      var result = await run(
          '<div><p>前面</p><img src="/img/a.jpg"/><p>后面</p></div>');
      print('顺序: ${result.blocks.map((b) => b.isImage ? "[img]" : b.text).toList()}');
      expect(result.blocks.length, 3);
      expect(result.blocks[1].isImage, isTrue);
      expect(result.blocks[1].imageUrl, 'https://example.com/img/a.jpg');
      expect(result.blocks[2].text, '后面');

      // 2. Lazy loading: the real url is in data-src, src is a placeholder.
      result = await run(
          '<p>x</p><img class="lazy" src="/static/blank.gif" data-src="https://cdn.test/real.jpg">');
      final lazy = result.blocks.where((b) => b.isImage).toList();
      print('懒加载: ${lazy.map((b) => b.imageUrl).toList()}');
      expect(lazy.length, 1);
      expect(lazy.first.imageUrl, 'https://cdn.test/real.jpg',
          reason: '应优先取 data-src 而不是占位 src');

      // 3. Other lazy attribute names, plus a protocol-relative url.
      result = await run('<img data-original="//cdn.test/b.png">'
          '<img data-lazy-src="/c/d.webp">');
      final urls =
          result.blocks.where((b) => b.isImage).map((b) => b.imageUrl).toList();
      print('其他懒加载属性: $urls');
      expect(urls, [
        'https://cdn.test/b.png',
        'https://example.com/c/d.webp',
      ]);

      // 4. Images nested inside paragraphs, and <br> as a separator.
      result = await run(
          '<p>一<br>二</p><p><img src="e.jpg"></p><p>三</p>');
      print('嵌套/换行: '
          '${result.blocks.map((b) => b.isImage ? "[img]" : b.text).toList()}');
      expect(result.textLines, ['一', '二', '三']);
      expect(result.blocks.where((b) => b.isImage).length, 1);
      expect(result.blocks.where((b) => b.isImage).first.imageUrl,
          'https://example.com/novel/1/e.jpg',
          reason: '相对路径应基于章节地址解析');

      // 5. Inline data: images are decoration, not illustrations.
      result = await run('<p>t</p><img src="data:image/gif;base64,R0lGOD">');
      expect(result.blocks.where((b) => b.isImage), isEmpty);

      // 6. HTML entities must be decoded in the text.
      result = await run('<p>&quot;引号&quot; &amp; &#31661;头 &nbsp;尾</p>');
      print('实体解码: "${result.textLines.first}"');
      expect(result.textLines.first, '"引号" & 箭头 尾');

      service.dispose();
      print('\n所有 htmlToBlocks 用例通过');
    });
  }, timeout: const Timeout(Duration(minutes: 3)));
}
