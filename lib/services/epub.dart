import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';

/// One readable document in an EPUB's reading order.
class EpubChapter {
  final String title;

  /// Path of the document inside the archive.
  final String href;

  const EpubChapter({required this.title, required this.href});
}

/// Minimal EPUB 2/3 reader: enough to list the reading order and render a
/// chapter's text and artwork. Uses only the zip + XML packaging, so it works
/// for both spec versions without a full ebook library.
class EpubBook {
  final String path;
  final String title;
  final String author;
  final String coverPath;
  final List<EpubChapter> chapters;

  const EpubBook({
    required this.path,
    required this.title,
    required this.author,
    required this.coverPath,
    required this.chapters,
  });

  static String? _cachedPath;
  static Archive? _cachedArchive;

  /// Decode from bytes rather than a file stream: the decoder keeps the stream
  /// alive for lazy reads, which pins an open handle on the file (on Windows
  /// that blocks deleting or moving the book). Chapters are read repeatedly, so
  /// the last archive is cached instead of re-parsed each time.
  static Archive _open(String path) {
    if (_cachedPath == path && _cachedArchive != null) return _cachedArchive!;
    final archive = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
    _cachedPath = path;
    _cachedArchive = archive;
    return archive;
  }

  static ArchiveFile? _find(Archive archive, String name) {
    final wanted = _normalise(name);
    for (final file in archive) {
      if (_normalise(file.name) == wanted) return file;
    }
    return null;
  }

  static String _normalise(String p) =>
      p.replaceAll('\\', '/').replaceAll(RegExp(r'^\./'), '');

  static String _decode(ArchiveFile file) {
    final bytes = file.readBytes() ?? const <int>[];
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  /// Resolve `ref` (which may contain ../) against the directory of `base`.
  static String _resolve(String base, String ref) {
    final target = ref.split('#').first;
    if (target.startsWith('/')) return _normalise(target.substring(1));
    final baseDir = _normalise(base).contains('/')
        ? _normalise(base).substring(0, _normalise(base).lastIndexOf('/'))
        : '';
    final segments = <String>[
      if (baseDir.isNotEmpty) ...baseDir.split('/'),
      ...target.split('/'),
    ];
    final out = <String>[];
    for (final segment in segments) {
      if (segment == '.' || segment.isEmpty) continue;
      if (segment == '..') {
        if (out.isNotEmpty) out.removeLast();
        continue;
      }
      out.add(segment);
    }
    return out.join('/');
  }

  static Future<EpubBook> open(String path) async {
    final archive = _open(path);

    // 1. META-INF/container.xml points at the package document.
    final container = _find(archive, 'META-INF/container.xml');
    if (container == null) throw Exception('不是有效的 EPUB：缺少 container.xml');
    final rootFile = XmlDocument.parse(_decode(container))
        .findAllElements('rootfile', namespaceUri: '*')
        .map((e) => e.getAttribute('full-path'))
        .firstWhere((e) => e != null && e.isNotEmpty,
            orElse: () => throw Exception('EPUB 损坏：container.xml 未指向 OPF'))!;

    final opfFile = _find(archive, rootFile);
    if (opfFile == null) throw Exception('EPUB 损坏：找不到 $rootFile');
    final opf = XmlDocument.parse(_decode(opfFile));

    // Metadata lives in the Dublin Core namespace (<dc:title>), so match on
    // local name rather than the qualified one.
    String meta(String name) {
      for (final e in opf.findAllElements(name, namespaceUri: '*')) {
        final text = e.innerText.trim();
        if (text.isNotEmpty) return text;
      }
      return '';
    }

    // 2. Manifest: id -> href, plus the declared cover image if there is one.
    final hrefById = <String, String>{};
    final idByProperty = <String, String>{};
    String? coverImageHref;
    for (final item in opf.findAllElements('item', namespaceUri: '*')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id == null || href == null) continue;
      hrefById[id] = _resolve(rootFile, href);
      final properties = item.getAttribute('properties') ?? '';
      if (properties.contains('cover-image')) {
        coverImageHref = hrefById[id];
      }
      if (properties.isNotEmpty) idByProperty[properties] = id;
    }
    if (coverImageHref == null) {
      // EPUB 2 declares the cover through a <meta name="cover" content="id">.
      for (final m in opf.findAllElements('meta', namespaceUri: '*')) {
        if (m.getAttribute('name') == 'cover') {
          coverImageHref = hrefById[m.getAttribute('content') ?? ''];
        }
      }
    }

    // 3. Titles come from the navigation document when one is present.
    final titleByHref = <String, String>{};
    final ncx = archive.files.where(
        (f) => f.name.toLowerCase().endsWith('.ncx') && f.isFile);
    for (final file in ncx) {
      try {
        final doc = XmlDocument.parse(_decode(file));
        for (final point in doc.findAllElements('navPoint', namespaceUri: '*')) {
          final label = point.findAllElements('text', namespaceUri: '*').firstOrNull?.innerText.trim();
          final src = point
              .findAllElements('content', namespaceUri: '*')
              .firstOrNull
              ?.getAttribute('src');
          if (label != null && src != null && label.isNotEmpty) {
            titleByHref[_resolve(file.name, src)] = label;
          }
        }
      } catch (_) {
        // A malformed nav file should not stop the book from opening.
      }
    }
    if (titleByHref.isEmpty) {
      for (final file in archive.files.where(
          (f) => f.isFile && f.name.toLowerCase().endsWith('nav.xhtml'))) {
        try {
          final doc = html_parser.parse(_decode(file));
          for (final a in doc.querySelectorAll('nav a[href]')) {
            final label = a.text.trim();
            if (label.isEmpty) continue;
            titleByHref[_resolve(file.name, a.attributes['href']!)] = label;
          }
        } catch (_) {}
      }
    }

    // 4. Spine defines the reading order.
    final chapters = <EpubChapter>[];
    for (final ref in opf.findAllElements('itemref', namespaceUri: '*')) {
      final href = hrefById[ref.getAttribute('idref') ?? ''];
      if (href == null) continue;
      if (_find(archive, href) == null) continue;
      chapters.add(EpubChapter(
        title: titleByHref[href] ?? '第 ${chapters.length + 1} 节',
        href: href,
      ));
    }
    if (chapters.isEmpty) throw Exception('EPUB 里没有可读章节');

    var cover = '';
    if (coverImageHref != null) {
      cover = await _extractResource(path, archive, coverImageHref) ?? '';
    }

    return EpubBook(
      path: path,
      title: meta('title'),
      author: meta('creator'),
      coverPath: cover,
      chapters: chapters,
    );
  }

  /// Chapter body as ordered blocks: strings for text, {'type':'image'} maps
  /// for artwork, matching what the JS extensions emit.
  static Future<List<dynamic>> readChapter(String path, String href) async {
    final archive = _open(path);
    final file = _find(archive, href);
    if (file == null) throw Exception('章节不存在: $href');

    final document = html_parser.parse(_decode(file));
    final blocks = <dynamic>[];
    final buffer = StringBuffer();

    void flush() {
      final text = buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isNotEmpty) blocks.add(text);
      buffer.clear();
    }

    Future<void> walk(dom.Node node) async {
      if (node is dom.Text) {
        buffer.write(node.text);
        return;
      }
      if (node is! dom.Element) return;

      final tag = node.localName?.toLowerCase();
      if (tag == 'img' || tag == 'image') {
        final src = node.attributes['src'] ??
            node.attributes['xlink:href'] ??
            node.attributes['href'];
        if (src != null && src.isNotEmpty && !src.startsWith('data:')) {
          flush();
          final extracted =
              await _extractResource(path, archive, _resolve(href, src));
          if (extracted != null) {
            blocks.add({'type': 'image', 'url': extracted});
          }
        }
        return;
      }
      if (tag == 'br') {
        flush();
        return;
      }
      if (tag == 'style' || tag == 'script') return;

      for (final child in node.nodes) {
        await walk(child);
      }

      // Block-level elements end a paragraph.
      const blockTags = {
        'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li', 'tr', 'section'
      };
      if (blockTags.contains(tag)) flush();
    }

    final body = document.body;
    if (body != null) {
      for (final child in body.nodes) {
        await walk(child);
      }
    }
    flush();
    return blocks;
  }

  /// Unpack one embedded file into the cache and return its path.
  static Future<String?> _extractResource(
      String epubPath, Archive archive, String href) async {
    final file = _find(archive, href);
    if (file == null) return null;

    final cacheRoot = await getTemporaryDirectory();
    final dir = Directory('${cacheRoot.path}${Platform.pathSeparator}local_epub'
        '${Platform.pathSeparator}${epubPath.hashCode.toRadixString(16)}');
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final safe = href.replaceAll(RegExp(r'[\\/]'), '_');
    final out = File('${dir.path}${Platform.pathSeparator}$safe');
    if (!out.existsSync() || out.lengthSync() == 0) {
      out.writeAsBytesSync(file.readBytes() ?? const []);
    }
    return out.path;
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
