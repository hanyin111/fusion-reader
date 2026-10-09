/// Core data models shared across the app.
library;

import 'comments.dart';
export 'comments.dart';

/// The three content categories. Miru uses `manga` / `fikushon` / `bangumi`,
/// we accept those plus plain english aliases.
enum MediaType {
  manga,
  novel,
  anime;

  static MediaType fromString(String s) {
    switch (s.toLowerCase().trim()) {
      case 'manga':
        return MediaType.manga;
      case 'fikushon':
      case 'novel':
        return MediaType.novel;
      case 'bangumi':
      case 'anime':
        return MediaType.anime;
      default:
        return MediaType.manga;
    }
  }

  String get label {
    switch (this) {
      case MediaType.manga:
        return '漫画';
      case MediaType.novel:
        return '小说';
      case MediaType.anime:
        return '动画';
    }
  }
}

/// Metadata parsed from the `// ==MiruExtension== ... // ==/MiruExtension==`
/// comment header of an extension script.
class ExtensionMeta {
  final String name;
  final String package;
  final String version;
  final String author;
  final String lang;
  final String webSite;
  final MediaType type;
  final String icon;
  final bool nsfw;
  final CommentScope? commentScope;

  /// Declared default network routing: 'auto' | 'direct' | 'proxy'.
  /// This is an internal compatibility default supplied by the extension.
  final String network;

  const ExtensionMeta({
    required this.name,
    required this.package,
    required this.version,
    required this.author,
    required this.lang,
    required this.webSite,
    required this.type,
    this.icon = '',
    this.nsfw = false,
    this.commentScope,
    this.network = 'auto',
  });

  static ExtensionMeta? parse(String script) {
    final headerMatch = RegExp(
      r'==MiruExtension==([\s\S]+?)==/MiruExtension==',
    ).firstMatch(script);
    if (headerMatch == null) return null;
    final fields = <String, String>{};
    for (final line in headerMatch.group(1)!.split('\n')) {
      final m = RegExp(r'@(\w+)\s+(.+)').firstMatch(line);
      if (m != null) fields[m.group(1)!] = m.group(2)!.trim();
    }
    if (fields['package'] == null || fields['type'] == null) return null;
    return ExtensionMeta(
      name: fields['name'] ?? fields['package']!,
      package: fields['package']!,
      version: fields['version'] ?? 'v0.0.1',
      author: fields['author'] ?? '',
      lang: fields['lang'] ?? 'all',
      webSite: fields['webSite'] ?? '',
      type: MediaType.fromString(fields['type']!),
      icon: fields['icon'] ?? '',
      nsfw: (fields['nsfw'] ?? 'false') == 'true',
      commentScope: CommentScope.parse(fields['comments']),
      network: fields['network'] ?? 'auto',
    );
  }
}

/// One item in a listing (latest / search results) or in the library.
class MediaItem {
  final String package;
  final MediaType type;
  final String title;
  final String url;
  final String cover;
  final String update;

  const MediaItem({
    required this.package,
    required this.type,
    required this.title,
    required this.url,
    this.cover = '',
    this.update = '',
  });

  String get key => '$package|$url';

  Map<String, dynamic> toJson() => {
        'package': package,
        'type': type.name,
        'title': title,
        'url': url,
        'cover': cover,
        'update': update,
      };

  factory MediaItem.fromJson(Map json) => MediaItem(
        package: json['package'] ?? '',
        type: MediaType.fromString(json['type'] ?? 'manga'),
        title: json['title'] ?? '',
        url: json['url'] ?? '',
        cover: json['cover'] ?? '',
        update: json['update'] ?? '',
      );

  factory MediaItem.fromExtension(Map json, ExtensionMeta meta) => MediaItem(
        package: meta.package,
        type: meta.type,
        title: (json['title'] ?? '').toString(),
        url: (json['url'] ?? '').toString(),
        cover: (json['cover'] ?? '').toString(),
        update: (json['update'] ?? '').toString(),
      );
}

/// A browse channel offered by a source: a category, ranking or sort order.
class MediaChannel {
  final String title;
  final String key;
  const MediaChannel({required this.title, required this.key});
}

/// A single playable / readable unit (chapter or episode).
class MediaEpisode {
  final String name;
  final String url;
  const MediaEpisode({required this.name, required this.url});
}

/// A named group of episodes (e.g. a scanlation group, or sub/dub).
class MediaEpisodeGroup {
  final String title;
  final List<MediaEpisode> urls;
  const MediaEpisodeGroup({required this.title, required this.urls});
}

/// A work's author, optionally carrying the source's author identifier/link.
class MediaAuthor {
  final String name;
  final String id;
  final String url;

  const MediaAuthor({required this.name, this.id = '', this.url = ''});

  Map<String, String> toJson() => {'name': name, 'id': id, 'url': url};
}

/// Result of `detail(url)`.
class MediaDetail {
  final String title;
  final String cover;
  final String desc;
  final List<MediaEpisodeGroup> episodes;
  final List<MediaAuthor> authors;

  const MediaDetail({
    required this.title,
    required this.cover,
    required this.desc,
    required this.episodes,
    this.authors = const [],
  });

  Map<String, dynamic> toJson() => {
    'title': title,
    'cover': cover,
    'desc': desc,
    'authors': authors.map((author) => author.toJson()).toList(),
    'episodes': [
      for (final group in episodes)
        {
          'title': group.title,
          'urls': [
            for (final episode in group.urls)
              {'name': episode.name, 'url': episode.url},
          ],
        },
    ],
  };

  // Old Miru scripts put the work's author in the description. Recognize only
  // an explicit metadata line, never the extension developer's @author field.
  static final _authorLine = RegExp(
    r'^\s*(?:作者|著者|Author(?:s|\(s\))?)[ \t]*[:：][ \t]*([^\r\n]+)',
    caseSensitive: false,
  );

  String get descriptionWithoutAuthor {
    final match = _authorLine.firstMatch(desc);
    if (authors.isEmpty || match == null) return desc;
    return desc.substring(match.end).trimLeft();
  }

  factory MediaDetail.fromJson(Map json) {
    final desc = (json['desc'] ?? '').toString();
    final authorData = json['authors'] ?? json['author'];
    final rawAuthors = authorData is List
        ? authorData
        : authorData == null
        ? const []
        : [authorData];
    final authors = <MediaAuthor>[];
    final seen = <String>{};
    for (final raw in rawAuthors) {
      final author = raw is String
          ? MediaAuthor(name: raw.trim())
          : raw is Map
          ? MediaAuthor(
              name: (raw['name'] ?? '').toString().trim(),
              id: (raw['id'] ?? '').toString(),
              url: (raw['url'] ?? '').toString(),
            )
          : null;
      if (author == null || author.name.isEmpty) continue;
      final key = author.id.isEmpty ? author.name.toLowerCase() : author.id;
      if (seen.add(key)) authors.add(author);
    }
    if (authors.isEmpty) {
      final legacyName = _authorLine.firstMatch(desc)?.group(1)?.trim();
      if (legacyName != null && legacyName.isNotEmpty) {
        authors.add(MediaAuthor(name: legacyName));
      }
    }
    final groups = <MediaEpisodeGroup>[];
    for (final g in (json['episodes'] as List? ?? [])) {
      if (g is! Map) continue;
      final eps = <MediaEpisode>[];
      for (final e in (g['urls'] as List? ?? [])) {
        if (e is! Map) continue;
        eps.add(
          MediaEpisode(
            name: (e['name'] ?? '').toString(),
            url: (e['url'] ?? '').toString(),
          ),
        );
      }
      groups.add(
        MediaEpisodeGroup(title: (g['title'] ?? '').toString(), urls: eps),
      );
    }
    return MediaDetail(
      title: (json['title'] ?? '').toString(),
      cover: (json['cover'] ?? '').toString(),
      desc: desc,
      episodes: groups,
      authors: authors,
    );
  }
}

/// Result of `watch(url)` for manga: a list of image urls.
class MangaWatch {
  final List<String> urls;
  final Map<String, String> headers;

  /// Optional per-result routing override ('direct' | 'proxy'). Some sites
  /// serve their HTML and their media over different network paths.
  final String? netMode;

  const MangaWatch({required this.urls, this.headers = const {}, this.netMode});

  factory MangaWatch.fromJson(Map json) => MangaWatch(
        urls: (json['urls'] as List? ?? []).map((e) => e.toString()).toList(),
        headers: _headers(json),
        netMode: json['netMode']?.toString(),
      );
}

/// One piece of a novel chapter: a paragraph or an inline illustration.
class NovelBlock {
  final String text;
  final String imageUrl;

  const NovelBlock.text(this.text) : imageUrl = '';
  const NovelBlock.image(this.imageUrl) : text = '';

  bool get isImage => imageUrl.isNotEmpty;
}

/// Result of `watch(url)` for novels: text content, possibly with artwork.
class NovelWatch {
  final List<NovelBlock> blocks;
  final String subtitle;
  final Map<String, String> headers;
  final String? netMode;

  const NovelWatch({
    required this.blocks,
    this.subtitle = '',
    this.headers = const {},
    this.netMode,
  });

  /// Plain-text paragraphs only — used where artwork is irrelevant.
  List<String> get textLines =>
      blocks.where((b) => !b.isImage).map((b) => b.text).toList();

  factory NovelWatch.fromJson(Map json) {
    final raw = json['content'];
    final blocks = <NovelBlock>[];

    void addEntry(dynamic entry) {
      if (entry is Map) {
        // Extensions emit {type:'image', url:'…'} for illustrations.
        final url = (entry['url'] ?? '').toString();
        if (entry['type'] == 'image' && url.isNotEmpty) {
          blocks.add(NovelBlock.image(url));
          return;
        }
        final text = (entry['text'] ?? '').toString();
        if (text.isNotEmpty) blocks.add(NovelBlock.text(text));
        return;
      }
      final text = entry.toString();
      if (text.trim().isNotEmpty) blocks.add(NovelBlock.text(text));
    }

    if (raw is List) {
      for (final entry in raw) {
        addEntry(entry);
      }
    } else {
      for (final line in (raw ?? '').toString().split('\n')) {
        addEntry(line);
      }
    }

    return NovelWatch(
      blocks: blocks,
      subtitle: (json['subtitle'] ?? '').toString(),
      headers: _headers(json),
      netMode: json['netMode']?.toString(),
    );
  }
}

/// Result of `watch(url)` for anime: a stream url.
class AnimeWatch {
  final String type; // 'hls' | 'mp4'
  final String url;
  final Map<String, String> headers;

  /// Optional per-result routing override ('direct' | 'proxy') for the player.
  final String? netMode;

  const AnimeWatch({
    required this.type,
    required this.url,
    this.headers = const {},
    this.netMode,
  });

  factory AnimeWatch.fromJson(Map json) => AnimeWatch(
        type: (json['type'] ?? 'mp4').toString(),
        url: (json['url'] ?? '').toString(),
        headers: _headers(json),
        netMode: json['netMode']?.toString(),
      );
}

Map<String, String> _headers(Map json) {
  final h = json['headers'];
  if (h is Map) {
    return h.map((k, v) => MapEntry(k.toString(), v.toString()));
  }
  return const {};
}

/// Reading/watching progress for one media item.
class HistoryRecord {
  final String key; // package|url
  // Older releases only stored chapter progress, without the work's metadata.
  final MediaItem? item;
  final String episodeUrl;
  final String episodeName;
  final int groupIndex;
  final int episodeIndex;
  final int timestamp;

  /// Position *within* the episode: page index for comics, paragraph index for
  /// novels, playback milliseconds for video.
  final int position;

  /// UTF-16 offset inside a novel paragraph; page numbers change with layout.
  final int textOffset;

  const HistoryRecord({
    required this.key,
    this.item,
    required this.episodeUrl,
    required this.episodeName,
    required this.groupIndex,
    required this.episodeIndex,
    required this.timestamp,
    this.position = 0,
    this.textOffset = 0,
  });

  bool get hasProgress => episodeUrl.isNotEmpty;

  HistoryRecord copyWith({
    MediaItem? item,
    int? position,
    int? textOffset,
    int? timestamp,
  }) => HistoryRecord(
    key: key,
    item: item ?? this.item,
    episodeUrl: episodeUrl,
    episodeName: episodeName,
    groupIndex: groupIndex,
    episodeIndex: episodeIndex,
    timestamp: timestamp ?? this.timestamp,
    position: position ?? this.position,
    textOffset: textOffset ?? this.textOffset,
  );

  Map<String, dynamic> toJson() => {
    'key': key,
    if (item != null) 'item': item!.toJson(),
    'episodeUrl': episodeUrl,
    'episodeName': episodeName,
    'groupIndex': groupIndex,
    'episodeIndex': episodeIndex,
    'timestamp': timestamp,
    'position': position,
    if (textOffset != 0) 'textOffset': textOffset,
  };

  factory HistoryRecord.fromJson(Map json) => HistoryRecord(
    key: json['key'] ?? '',
    item: json['item'] is Map ? MediaItem.fromJson(json['item']) : null,
    episodeUrl: json['episodeUrl'] ?? '',
    episodeName: json['episodeName'] ?? '',
    groupIndex: json['groupIndex'] ?? 0,
    episodeIndex: json['episodeIndex'] ?? 0,
    timestamp: json['timestamp'] ?? 0,
    position: json['position'] ?? 0,
    textOffset: json['textOffset'] ?? 0,
  );
}
