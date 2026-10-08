enum CommentScope {
  chapter,
  work;

  String get label => this == chapter ? '章节评论' : '作品评论';

  static CommentScope? parse(String? value) => switch (value) {
    'chapter' => chapter,
    'work' => work,
    _ => null,
  };
}

int _integer(dynamic value) => int.tryParse(value.toString()) ?? 0;
bool _flag(dynamic value) => value == true || value == 1 || value == '1';

class MediaComment {
  final String id;
  final String username;
  final String text;
  final String time;
  final int likes;
  final int replyCount;
  final bool spoiler;
  final bool hidden;
  final bool pinned;
  final List<String> images;

  const MediaComment({
    required this.id,
    required this.username,
    required this.text,
    this.time = '',
    this.likes = 0,
    this.replyCount = 0,
    this.spoiler = false,
    this.hidden = false,
    this.pinned = false,
    this.images = const [],
  });

  String get key => id.isNotEmpty ? id : '$username|$time|$text';

  factory MediaComment.fromJson(Map json) => MediaComment(
    id: (json['id'] ?? '').toString(),
    username: (json['username'] ?? '匿名读者').toString(),
    text: (json['text'] ?? '').toString(),
    time: (json['time'] ?? '').toString(),
    likes: _integer(json['likes']),
    replyCount: _integer(json['replyCount']),
    spoiler: _flag(json['spoiler']),
    hidden: _flag(json['hidden']),
    pinned: _flag(json['pinned']),
    images: (json['images'] as List? ?? [])
        .whereType<String>()
        .where(
          (url) => RegExp(r'^https?://', caseSensitive: false).hasMatch(url),
        )
        .toList(),
  );
}

class CommentPage {
  final List<MediaComment> comments;
  final bool hasMore;
  final int? total;
  final Map<String, String> headers;

  const CommentPage({
    required this.comments,
    required this.hasMore,
    this.total,
    this.headers = const {},
  });

  factory CommentPage.fromJson(Map json) => CommentPage(
    comments: (json['comments'] as List? ?? [])
        .whereType<Map>()
        .map(MediaComment.fromJson)
        .toList(),
    hasMore: _flag(json['hasMore']),
    total: json['total'] == null ? null : _integer(json['total']),
    headers: (json['headers'] as Map? ?? {}).map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    ),
  );
}
