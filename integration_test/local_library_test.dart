// Exercises local import against generated fixtures: an image folder, a cbz,
// a UTF-8 novel, a GBK novel and a video file.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/services/local_library.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

List<int> pngBytes(int seed) {
  final image = img.Image(width: 40, height: 60);
  img.fill(image, color: img.ColorRgb8(seed * 40 % 255, 80, 160));
  return img.encodePng(image);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('local import handles comics, novels and video', (tester) async {
    await tester.runAsync(() async {
      await Storage.init();

      final root = Directory(
          '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}fusion_local_test');
      if (root.existsSync()) root.deleteSync(recursive: true);
      root.createSync(recursive: true);
      String p(String name) => '${root.path}${Platform.pathSeparator}$name';

      // ---- fixture 1: comic folder with two chapter subfolders ----
      final comicRoot = Directory(p('MyComic'))..createSync();
      for (final chapter in ['第1话', '第2话']) {
        final dir = Directory(
            '${comicRoot.path}${Platform.pathSeparator}$chapter')
          ..createSync();
        // Deliberately out of lexical order to prove natural sorting.
        for (final n in [1, 2, 10]) {
          File('${dir.path}${Platform.pathSeparator}$n.png')
              .writeAsBytesSync(pngBytes(n));
        }
      }

      // ---- fixture 2: cbz archive ----
      final archive = Archive();
      for (final n in [1, 2, 10]) {
        final bytes = pngBytes(n);
        archive.add(ArchiveFile('pages/$n.png', bytes.length, bytes));
      }
      File(p('Volume.cbz')).writeAsBytesSync(ZipEncoder().encode(archive));

      // ---- fixture 3: novels, one UTF-8 and one GBK ----
      const novelText = '序章\n开篇的一段文字。\n\n第1章 出发\n第一章的内容。\n\n'
          '第2章 抵达\n第二章的内容，稍微长一点，用来确认切分没有丢字。\n';
      File(p('book_utf8.txt')).writeAsStringSync(novelText);
      File(p('book_gbk.txt')).writeAsBytesSync(gbk.encode(novelText));

      // ---- fixture 4: a minimal but spec-shaped EPUB with an illustration ----
      final epub = Archive();
      void addText(String name, String body) {
        final bytes = utf8.encode(body);
        epub.add(ArchiveFile(name, bytes.length, bytes));
      }
      addText('mimetype', 'application/epub+zip');
      addText('META-INF/container.xml', '''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf"
    media-type="application/oebps-package+xml"/></rootfiles>
</container>''');
      addText('OEBPS/content.opf', '''
<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>测试电子书</dc:title>
    <dc:creator>某作者</dc:creator>
  </metadata>
  <manifest>
    <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="pic" href="images/pic.png" media-type="image/png" properties="cover-image"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
  </manifest>
  <spine toc="ncx"><itemref idref="c1"/><itemref idref="c2"/></spine>
</package>''');
      addText('OEBPS/toc.ncx', '''
<?xml version="1.0"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <navMap>
    <navPoint id="n1" playOrder="1"><navLabel><text>第一章 启程</text></navLabel>
      <content src="text/ch1.xhtml"/></navPoint>
    <navPoint id="n2" playOrder="2"><navLabel><text>第二章 插图页</text></navLabel>
      <content src="text/ch2.xhtml"/></navPoint>
  </navMap>
</ncx>''');
      addText('OEBPS/text/ch1.xhtml', '''
<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><body>
<h1>第一章 启程</h1><p>这是第一章的正文段落。</p><p>第二段内容。</p>
</body></html>''');
      // The image path is relative and needs resolving against the document.
      addText('OEBPS/text/ch2.xhtml', '''
<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><body>
<p>插图前的文字。</p>
<div><img src="../images/pic.png" alt="illustration"/></div>
<p>插图后的文字。</p>
</body></html>''');
      final pic = pngBytes(7);
      epub.add(ArchiveFile('OEBPS/images/pic.png', pic.length, pic));
      File(p('book.epub')).writeAsBytesSync(ZipEncoder().encode(epub));

      // ---- fixture 5: a video file (metadata only; no playback here) ----
      File(p('episode01.mp4')).writeAsBytesSync(List.filled(2048, 0));

      final report = StringBuffer('\n===== LOCAL IMPORT REPORT =====\n');

      // ---- comic folder ----
      final comic = await LocalLibrary.import(comicRoot.path, MediaType.manga);
      final comicDetail = await LocalLibrary.detail(comic);
      final chapters = comicDetail.episodes.first.urls;
      report.writeln('[漫画文件夹] ${comic.title}: ${chapters.length} 章'
          ' -> ${chapters.map((e) => e.name).join(', ')}');
      expect(chapters.length, 2, reason: '应识别出 2 个章节文件夹');

      final pages = MangaWatch.fromJson(
          await LocalLibrary.watch(comic, chapters.first.url));
      report.writeln('     第一章 ${pages.urls.length} 页: '
          '${pages.urls.map((u) => u.split(Platform.pathSeparator).last).join(', ')}');
      expect(pages.urls.length, 3);
      // 10.png must sort last, not between 1 and 2.
      expect(pages.urls.last.endsWith('10.png'), isTrue,
          reason: '自然排序失败: ${pages.urls}');
      for (final page in pages.urls) {
        expect(File(page).lengthSync(), greaterThan(50), reason: '页面文件为空: $page');
      }
      expect(comic.cover.isNotEmpty, isTrue, reason: '未能生成封面');
      report.writeln('     封面: ${comic.cover.split(Platform.pathSeparator).last}');

      // ---- cbz ----
      final cbz = await LocalLibrary.import(p('Volume.cbz'), MediaType.manga);
      final cbzPages = MangaWatch.fromJson(await LocalLibrary.watch(
          cbz, (await LocalLibrary.detail(cbz)).episodes.first.urls.first.url));
      report.writeln('[压缩包] ${cbz.title}: 解出 ${cbzPages.urls.length} 页');
      expect(cbzPages.urls.length, 3, reason: 'cbz 解包页数不对');
      for (final page in cbzPages.urls) {
        expect(File(page).existsSync(), isTrue);
      }

      // ---- novels ----
      for (final entry in {'UTF-8': 'book_utf8.txt', 'GBK': 'book_gbk.txt'}.entries) {
        final novel = await LocalLibrary.import(p(entry.value), MediaType.novel);
        final detail = await LocalLibrary.detail(novel);
        final eps = detail.episodes.first.urls;
        final body = NovelWatch.fromJson(
            await LocalLibrary.watch(novel, eps[1].url));
        final text = body.textLines.join();
        report.writeln('[小说 ${entry.key}] ${eps.length} 章'
            ' -> ${eps.map((e) => e.name).join(' | ')}');
        report.writeln('     第2章正文: "$text"');
        expect(eps.length, 3, reason: '${entry.key} 章节切分错误');
        expect(text.contains('第一章的内容'), isTrue,
            reason: '${entry.key} 正文解码错误(可能是编码问题): $text');
      }

      // ---- epub ----
      final ebook = await LocalLibrary.import(p('book.epub'), MediaType.novel);
      final ebookDetail = await LocalLibrary.detail(ebook);
      final ebookChapters = ebookDetail.episodes.first.urls;
      report.writeln('[EPUB] ${ebookDetail.title} / ${ebookChapters.length} 章'
          ' -> ${ebookChapters.map((e) => e.name).join(' | ')}');
      expect(ebookDetail.title, '测试电子书', reason: 'OPF 元数据未读出');
      expect(ebookChapters.length, 2, reason: 'spine 阅读顺序解析错误');
      expect(ebookChapters.first.name, '第一章 启程', reason: 'toc.ncx 标题未读出');
      expect(ebook.cover.isNotEmpty && File(ebook.cover).existsSync(), isTrue,
          reason: '未取出 EPUB 封面');

      final ch1 = NovelWatch.fromJson(
          await LocalLibrary.watch(ebook, ebookChapters[0].url));
      expect(ch1.textLines.join().contains('第一章的正文段落'), isTrue,
          reason: 'EPUB 正文解析失败: ${ch1.textLines}');

      final ch2 = NovelWatch.fromJson(
          await LocalLibrary.watch(ebook, ebookChapters[1].url));
      final illustrations = ch2.blocks.where((b) => b.isImage).toList();
      report.writeln('     第二章 ${ch2.blocks.length} 块，'
          '其中插图 ${illustrations.length} 张');
      expect(illustrations.length, 1, reason: 'EPUB 插图未提取: ${ch2.blocks.length} 块');
      expect(File(illustrations.first.imageUrl).lengthSync(), greaterThan(50),
          reason: '插图文件为空');
      // Order matters: text, image, text.
      expect(ch2.blocks.first.isImage, isFalse);
      expect(ch2.blocks[1].isImage, isTrue, reason: '插图位置错乱: 应在首段之后');
      expect(ch2.blocks.last.text.contains('插图后'), isTrue);
      report.writeln('     顺序校验通过: 文字 → 插图 → 文字');

      // ---- video ----
      final video = await LocalLibrary.import(p('episode01.mp4'), MediaType.anime);
      final videoDetail = await LocalLibrary.detail(video);
      final episode = videoDetail.episodes.first.urls.first;
      final play = AnimeWatch.fromJson(await LocalLibrary.watch(video, episode.url));
      report.writeln('[视频] ${video.title} -> ${episode.name}');
      expect(play.url, p('episode01.mp4'));

      // ---- shelf integration ----
      final shelf = LocalLibrary.all();
      report.writeln('本地书架条目: ${shelf.length}');
      report.writeln('===============================');
      print(report.toString());
      expect(shelf.length, greaterThanOrEqualTo(5));

      // Cleanup must not mask a passing run, but a failure here would mean a
      // file handle is still pinned — so report it rather than swallowing it.
      try {
        root.deleteSync(recursive: true);
      } catch (e) {
        fail('临时目录无法删除，说明有文件句柄未释放: $e');
      }
    });
  }, timeout: const Timeout(Duration(minutes: 5)));
}
