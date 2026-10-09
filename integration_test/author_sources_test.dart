import 'repository_fixture.dart';
// Public catalogue checks; no account credentials or reading history needed.
// ignore_for_file: avoid_print
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/services/extension_runtime.dart';
import 'package:fusion_reader/services/storage.dart';

import 'linovelib_test.dart' show isolateLinovelibTestStorage;

void main() {
  isolateLinovelibTestStorage();
  testWidgets(
    'live novel and manga author catalogues return other works',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('正在验证作者作品查询'))),
      );
      await tester.runAsync(() async {
        await Storage.init();
        final prelude = await rootBundle.loadString('assets/js/runtime.js');
        for (final package in ['linovelib', 'weebcentral']) {
          final script = await repositoryFixture(package);
          final service = ExtensionService(
            meta: ExtensionMeta.parse(script)!,
            script: script,
            prelude: prelude,
          );
          await service.init();
          try {
            final detail = await service.detail(
              package == 'linovelib'
                  ? '/novel/2139.html'
                  : '/series/01J76XY7E827QQQT0ERKCGH4CD/Naruto',
            );
            expect(detail.authors, isNotEmpty);
            final author = detail.authors.first;
            expect(
              author.name,
              package == 'linovelib' ? '长月达平' : 'KISHIMOTO Masashi',
            );
            final works = await service.searchAuthor(author, 1);
            expect(works.length, greaterThan(1));
            expect(works.every((work) => work.package == package), isTrue);
            expect(
              works.every((work) => work.type == service.meta.type),
              isTrue,
            );
            if (package == 'linovelib') {
              expect(
                works.map((w) => w.url),
                containsAll(['/novel/2139.html', '/novel/5367.html']),
              );
              expect(
                works.map((w) => w.url),
                isNot(contains('/novel/1.html')),
                reason: '混入搜索弹窗中的无关作品',
              );
              expect(await service.searchAuthor(author, 2), isEmpty);
            } else {
              expect(
                works.any((work) => work.title.contains('Boruto')),
                isTrue,
              );
            }
            print('$package: ${author.name}，${works.length} 部作品');
          } finally {
            service.dispose();
          }
        }
      });
      await tester.pump();
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
