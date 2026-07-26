import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';
import 'epub.dart';
import 'storage.dart';

/// Books, comics and videos imported from the device instead of a web source.
///
/// Local entries live on the same shelf as online ones by reusing [MediaItem]
/// with a reserved package name, so nothing downstream needs to special-case
/// them beyond resolving content through this class.
class LocalLibrary {
  static const package = 'local';

  static const imageExtensions = {
    '.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp', '.avif'
  };
  static const videoExtensions = {
    '.mp4', '.mkv', '.avi', '.mov', '.webm', '.flv', '.ts', '.m4v'
  };
  static const textExtensions = {'.txt'};
  static const epubExtensions = {'.epub'};
  static const archiveExtensions = {'.zip', '.cbz'};

  static bool isLocal(String package) => package == LocalLibrary.package;

  // ---------- import ----------

  /// Register a file or folder. Returns the shelf entry that was created.
  static Future<MediaItem> import(String path, MediaType type) async {
    final entity = FileSystemEntity.typeSync(path);
    if (entity == FileSystemEntityType.notFound) {
      throw Exception('找不到路径: $path');
    }
    final title = _baseName(path);
    final cover = await _findCover(path, type);
    final item = MediaItem(
      package: package,
      type: type,
      title: title,
      url: path,
      cover: cover,
    );
    await Storage.addLocalItem(item);
    return item;
  }

  static Future<void> remove(String path) => Storage.removeLocalItem(path);

  static List<MediaItem> all() => Storage.localItems();

  // ---------- content resolution ----------

  static Future<MediaDetail> detail(MediaItem item) async {
    switch (item.type) {
      case MediaType.manga:
        return _mangaDetail(item);
      case MediaType.novel:
        return _novelDetail(item);
      case MediaType.anime:
        return _animeDetail(item);
    }
  }

  static Future<MediaDetail> _mangaDetail(MediaItem item) async {
    final path = item.url;
    final episodes = <MediaEpisode>[];

    if (_isArchive(path)) {
      episodes.add(MediaEpisode(name: _baseName(path), url: path));
    } else if (FileSystemEntity.isDirectorySync(path)) {
      final dir = Directory(path);
      final children = dir.listSync().toList()..sort(_compareNatural);

      // A folder of chapter folders, or a single chapter of loose images.
      final subChapters = children
          .where((e) =>
              e is Directory ||
              (e is File && _isArchive(e.path)))
          .toList();
      if (subChapters.isNotEmpty) {
        for (final child in subChapters) {
          episodes.add(MediaEpisode(name: _baseName(child.path), url: child.path));
        }
      }
      if (_imagesIn(dir).isNotEmpty) {
        episodes.insert(0, MediaEpisode(name: _baseName(path), url: path));
      }
    } else {
      throw Exception('漫画需要选择图片文件夹或 zip/cbz 压缩包');
    }

    if (episodes.isEmpty) throw Exception('该位置没有找到任何图片');
    return MediaDetail(
      title: item.title,
      cover: item.cover,
      desc: '本地漫画\n$path',
      episodes: [MediaEpisodeGroup(title: '章节', urls: episodes)],
    );
  }

  static Future<MediaDetail> _novelDetail(MediaItem item) async {
    final path = item.url;
    final episodes = <MediaEpisode>[];

    if (_isEpub(path)) {
      final book = await EpubBook.open(path);
      for (final chapter in book.chapters) {
        // The href identifies the document inside the archive.
        episodes.add(MediaEpisode(name: chapter.title, url: '$path#${chapter.href}'));
      }
      return MediaDetail(
        title: book.title.isNotEmpty ? book.title : item.title,
        cover: book.coverPath.isNotEmpty ? book.coverPath : item.cover,
        desc: [
          if (book.author.isNotEmpty) '作者: ${book.author}',
          '本地 EPUB\n$path',
        ].join('\n'),
        episodes: [MediaEpisodeGroup(title: '章节', urls: episodes)],
      );
    }

    if (FileSystemEntity.isDirectorySync(path)) {
      for (final file in Directory(path).listSync().toList()..sort(_compareNatural)) {
        if (file is File &&
            (textExtensions.contains(_ext(file.path)) ||
                epubExtensions.contains(_ext(file.path)))) {
          episodes.add(MediaEpisode(name: _baseName(file.path), url: file.path));
        }
      }
      if (episodes.isEmpty) throw Exception('该文件夹里没有 .txt / .epub 文件');
    } else {
      // One text file usually holds a whole book, so split it into chapters.
      final text = await _readText(File(path));
      final marks = _chapterMarks(text);
      if (marks.length >= 2) {
        for (var i = 0; i < marks.length; i++) {
          episodes.add(MediaEpisode(
            name: marks[i].title,
            // The range is encoded in the url so watch() need not re-scan.
            url: '$path#${marks[i].start}-${marks[i].end}',
          ));
        }
      } else {
        episodes.add(MediaEpisode(name: '全文', url: path));
      }
    }

    return MediaDetail(
      title: item.title,
      cover: item.cover,
      desc: '本地小说\n$path',
      episodes: [MediaEpisodeGroup(title: '章节', urls: episodes)],
    );
  }

  static Future<MediaDetail> _animeDetail(MediaItem item) async {
    final path = item.url;
    final episodes = <MediaEpisode>[];
    if (FileSystemEntity.isDirectorySync(path)) {
      for (final file in Directory(path).listSync().toList()..sort(_compareNatural)) {
        if (file is File && videoExtensions.contains(_ext(file.path))) {
          episodes.add(MediaEpisode(name: _baseName(file.path), url: file.path));
        }
      }
      if (episodes.isEmpty) throw Exception('该文件夹里没有视频文件');
    } else {
      episodes.add(MediaEpisode(name: _baseName(path), url: path));
    }
    return MediaDetail(
      title: item.title,
      cover: item.cover,
      desc: '本地视频\n$path',
      episodes: [MediaEpisodeGroup(title: '剧集', urls: episodes)],
    );
  }

  /// Raw watch payload in the same shape extensions return.
  static Future<Map> watch(MediaItem item, String url) async {
    switch (item.type) {
      case MediaType.manga:
        return {'urls': await _mangaPages(url)};
      case MediaType.novel:
        return {'content': await _novelContent(url)};
      case MediaType.anime:
        return {'type': 'mp4', 'url': url};
    }
  }

  static Future<List<String>> _mangaPages(String path) async {
    if (_isArchive(path)) return _extractArchive(path);
    final dir = Directory(path);
    if (!dir.existsSync()) throw Exception('章节不存在: $path');
    return _imagesIn(dir).map((f) => f.path).toList();
  }

  /// Unpack a cbz/zip once into the cache directory and reuse it afterwards.
  static Future<List<String>> _extractArchive(String path) async {
    final cacheRoot = await getTemporaryDirectory();
    final target = Directory(
        '${cacheRoot.path}${Platform.pathSeparator}local_cbz${Platform.pathSeparator}'
        '${path.hashCode.toRadixString(16)}');
    if (!target.existsSync()) {
      target.createSync(recursive: true);
      // Decode from bytes so no file handle stays pinned on the archive.
      final archive = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
      for (final entry in archive) {
        if (!entry.isFile) continue;
        if (!imageExtensions.contains(_ext(entry.name))) continue;
        // Flatten nested folders; keep names unique and ordered.
        final safe = entry.name.replaceAll(RegExp(r'[\\/]'), '_');
        final out = File('${target.path}${Platform.pathSeparator}$safe');
        out.writeAsBytesSync(entry.readBytes() ?? const []);
      }
    }
    return _imagesIn(target).map((f) => f.path).toList();
  }

  static Future<List<dynamic>> _novelContent(String url) async {
    // EPUB chapters are addressed as "<file>#<href-inside-archive>".
    final hashIndex = url.lastIndexOf('#');
    if (hashIndex > 0 && _isEpub(url.substring(0, hashIndex))) {
      return EpubBook.readChapter(
          url.substring(0, hashIndex), url.substring(hashIndex + 1));
    }
    if (_isEpub(url)) {
      final book = await EpubBook.open(url);
      return EpubBook.readChapter(url, book.chapters.first.href);
    }

    var path = url;
    int? start;
    int? end;
    final hash = url.lastIndexOf('#');
    if (hash > 0) {
      final range = url.substring(hash + 1).split('-');
      if (range.length == 2) {
        start = int.tryParse(range[0]);
        end = int.tryParse(range[1]);
        path = url.substring(0, hash);
      }
    }

    final text = await _readText(File(path));
    final slice = (start != null && end != null)
        ? text.substring(start.clamp(0, text.length), end.clamp(0, text.length))
        : text;
    return slice
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  // ---------- helpers ----------

  /// Chinese ebooks are still commonly GBK-encoded, which would decode to
  /// mojibake if we assumed UTF-8 unconditionally.
  static Future<String> _readText(File file) async {
    final bytes = await file.readAsBytes();
    try {
      return utf8.decode(bytes);
    } on FormatException {
      try {
        return gbk.decode(bytes);
      } catch (_) {
        return utf8.decode(bytes, allowMalformed: true);
      }
    }
  }

  /// A heading is the marker alone, or the marker followed by a separator and
  /// a short title. Without the separator requirement a body line such as
  /// "第一章的内容。" would be mistaken for a new chapter.
  static final _chapterPattern = RegExp(
    r'^(?:序章|楔子|尾声|尾聲|后记|後記'
    r'|第\s*[0-9零一二三四五六七八九十百千两]+\s*[章节節回卷篇話话]'
    r'|(?:Chapter|CHAPTER|Vol\.?)\s*\d+)'
    r'(?:[\s:：、.．,，\-—－]+\S.{0,28})?$',
  );

  /// Real chapter headings are short lines; anything longer is prose.
  static const _maxHeadingLength = 40;

  static List<({String title, int start, int end})> _chapterMarks(String text) {
    final marks = <({String title, int start, int end})>[];
    final lines = text.split('\n');
    var offset = 0;
    final starts = <({String title, int at})>[];
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.length <= _maxHeadingLength &&
          _chapterPattern.hasMatch(trimmed)) {
        starts.add((title: trimmed, at: offset));
      }
      offset += line.length + 1;
    }
    for (var i = 0; i < starts.length; i++) {
      marks.add((
        title: starts[i].title,
        start: starts[i].at,
        end: i + 1 < starts.length ? starts[i + 1].at : text.length,
      ));
    }
    return marks;
  }

  static List<File> _imagesIn(Directory dir) {
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => imageExtensions.contains(_ext(f.path)))
        .toList()
      ..sort(_compareNatural);
    return files;
  }

  static Future<String> _findCover(String path, MediaType type) async {
    try {
      if (FileSystemEntity.isDirectorySync(path)) {
        final dir = Directory(path);
        final images = _imagesIn(dir);
        if (images.isNotEmpty) return images.first.path;
        // Fall back to the first image inside the first chapter folder.
        for (final child in dir.listSync().toList()..sort(_compareNatural)) {
          if (child is Directory) {
            final inner = _imagesIn(child);
            if (inner.isNotEmpty) return inner.first.path;
          }
        }
      } else if (_isArchive(path)) {
        final pages = await _extractArchive(path);
        if (pages.isNotEmpty) return pages.first;
      } else if (_isEpub(path)) {
        return (await EpubBook.open(path)).coverPath;
      }
    } catch (_) {
      // A missing cover is cosmetic; never block the import over it.
    }
    return '';
  }

  static bool _isArchive(String path) => archiveExtensions.contains(_ext(path));

  static bool _isEpub(String path) => epubExtensions.contains(_ext(path));

  static String _ext(String path) {
    final dot = path.lastIndexOf('.');
    return dot < 0 ? '' : path.substring(dot).toLowerCase();
  }

  static String _baseName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final trimmed =
        normalized.endsWith('/') ? normalized.substring(0, normalized.length - 1) : normalized;
    final slash = trimmed.lastIndexOf('/');
    return slash < 0 ? trimmed : trimmed.substring(slash + 1);
  }

  /// Sort "2" before "10" the way a reader expects, unlike plain string order.
  static int _compareNatural(FileSystemEntity a, FileSystemEntity b) {
    final x = _baseName(a.path).toLowerCase();
    final y = _baseName(b.path).toLowerCase();
    final chunk = RegExp(r'(\d+|\D+)');
    final xs = chunk.allMatches(x).map((m) => m.group(0)!).toList();
    final ys = chunk.allMatches(y).map((m) => m.group(0)!).toList();
    for (var i = 0; i < xs.length && i < ys.length; i++) {
      final nx = int.tryParse(xs[i]);
      final ny = int.tryParse(ys[i]);
      final cmp = (nx != null && ny != null)
          ? nx.compareTo(ny)
          : xs[i].compareTo(ys[i]);
      if (cmp != 0) return cmp;
    }
    return xs.length.compareTo(ys.length);
  }
}
