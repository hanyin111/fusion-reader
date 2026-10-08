import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';

void main() {
  test('old extensions do not advertise comments', () {
    final meta = ExtensionMeta.parse('''
// ==MiruExtension==
// @package old
// @type manga
// ==/MiruExtension==
''')!;
    expect(meta.commentScope, isNull);
    expect(CommentScope.parse('unknown'), isNull);
  });

  test('chapter and work capabilities remain distinct', () {
    for (final scope in CommentScope.values) {
      final meta = ExtensionMeta.parse('''
// ==MiruExtension==
// @package fixture
// @type manga
// @comments ${scope.name}
// ==/MiruExtension==
''')!;
      expect(meta.commentScope, scope);
    }
  });

  test('normalizes counts and spoiler/hidden flags', () {
    final comment = MediaComment.fromJson({
      'id': 12,
      'username': '读者',
      'text': '正文',
      'likes': '3',
      'replyCount': 2,
      'spoiler': '1',
      'hidden': false,
      'pinned': true,
    });
    expect(comment.key, '12');
    expect(comment.likes, 3);
    expect(comment.replyCount, 2);
    expect(comment.spoiler, isTrue);
    expect(comment.hidden, isFalse);
    expect(comment.pinned, isTrue);
  });

  test('comments cannot use local file paths or script URLs as images', () {
    final comment = MediaComment.fromJson({
      'images': [
        'https://site.example/image.jpg',
        'file:///private.txt',
        'C:/private.txt',
        'javascript:alert(1)',
        null,
      ],
    });
    expect(comment.images, ['https://site.example/image.jpg']);
  });

  test('empty pages retain explicit pagination and image headers', () {
    final page = CommentPage.fromJson({
      'comments': [],
      'hasMore': true,
      'total': '22',
      'headers': {'Referer': 'https://site.example/chapter'},
    });
    expect(page.comments, isEmpty);
    expect(page.hasMore, isTrue);
    expect(page.total, 22);
    expect(page.headers['Referer'], 'https://site.example/chapter');
  });
}
