import 'repository_fixture.dart';
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
    'live Linovelib comments are chapter-specific and unauthenticated Pica asks for account',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('正在验证评论查询'))),
      );
      await tester.runAsync(() async {
        await Storage.init();
        final prelude = await rootBundle.loadString('assets/js/runtime.js');
        for (final package in ['linovelib', 'picacg']) {
          final script = await repositoryFixture(package);
          final service = ExtensionService(
            meta: ExtensionMeta.parse(script)!,
            script: script,
            prelude: prelude,
          );
          await service.init();
          try {
            if (package == 'linovelib') {
              final first = await service.comments(
                '/novel/2139.html',
                '/novel/2139/76673.html',
                1,
              );
              final second = await service.comments(
                '/novel/2139.html',
                '/novel/2139/76674_2.html',
                1,
              );
              expect(first.comments, isNotEmpty);
              expect(second.comments, isNotEmpty);
              expect(
                first.comments
                    .map((c) => c.id)
                    .toSet()
                    .intersection(second.comments.map((c) => c.id).toSet()),
                isEmpty,
              );
              expect(
                first.comments.every((c) => !c.text.contains('<div')),
                isTrue,
              );
              expect(first.headers['User-Agent'], contains('Mobile'));
              final end = await service.comments(
                '/novel/2139.html',
                '/novel/2139/76673.html',
                2,
              );
              expect(end.comments, isEmpty);
              expect(end.hasMore, isFalse);
              print(
                '哔哩轻小说：序章 ${first.comments.length} 条，第一章 ${second.comments.length} 条，章节与分页验证通过。',
              );
            } else {
              await expectLater(
                service.comments('comic-id', 'comic-id/1', 1),
                throwsA(predicate((e) => e.toString().contains('未配置哔咔帐号'))),
              );
              print('哔咔：未配置账号时正确提示登录。');
            }
          } finally {
            service.dispose();
          }
        }
      });
      await tester.pump();
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
