import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';

void main() {
  test('structured authors preserve source IDs, links and separate names', () {
    final detail = MediaDetail.fromJson({
      'authors': [
        {'name': ' 作者甲 ', 'id': 'a', 'url': '/authors/a'},
        {'name': '作者乙', 'id': 'b'},
        {'name': '作者甲', 'id': 'a'},
        {'name': ''},
        null,
      ],
    });
    expect(detail.authors.map((a) => a.name), ['作者甲', '作者乙']);
    expect(detail.authors.first.toJson(), {
      'name': '作者甲',
      'id': 'a',
      'url': '/authors/a',
    });
  });

  test('legacy author lines become searchable without splitting commas', () {
    for (final label in ['作者：', '著者: ', 'Author: ', 'Author(s): ']) {
      final detail = MediaDetail.fromJson({
        'desc': '${label}Shelley, Mary Wollstonecraft\n\n简介正文',
      });
      expect(detail.authors.single.name, 'Shelley, Mary Wollstonecraft');
      expect(detail.descriptionWithoutAuthor, '简介正文');
      expect(detail.desc, startsWith(label));
    }
  });

  test('accepts singular author and string arrays from custom scripts', () {
    expect(MediaDetail.fromJson({'author': '作者甲'}).authors.single.name, '作者甲');
    expect(
      MediaDetail.fromJson({
        'authors': ['作者甲', '作者乙'],
      }).authors.map((a) => a.name),
      ['作者甲', '作者乙'],
    );
  });

  test('does not infer authors from empty labels or narrative text', () {
    for (final desc in ['作者：\n简介正文', '故事中的作者：角色甲', '简介正文']) {
      final detail = MediaDetail.fromJson({'desc': desc});
      expect(detail.authors, isEmpty);
      expect(detail.descriptionWithoutAuthor, desc);
    }
  });
}
