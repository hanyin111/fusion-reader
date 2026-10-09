import 'repository_fixture.dart';
// Opt in with FUSION_VERIFY_PICACG_ACCOUNT=1 after closing the normal app.
// Uses the account already configured in the app; never prints credentials,
// installs fixtures, posts comments, likes anything, or changes reading history.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/services/extension_runtime.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'configured Pica account can read comic comments and replies',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('正在验证哔咔作品评论'))),
      );
      await tester.runAsync(() async {
        await Storage.init();
        final hasAccount =
            (Storage.extSetting('picacg', 'email') ?? '')
                .toString()
                .isNotEmpty &&
            (Storage.extSetting('picacg', 'password') ?? '')
                .toString()
                .isNotEmpty;
        if (!hasAccount) {
          print('PICACG_ACCOUNT_NOT_CONFIGURED: 登录后的在线评论验证跳过。');
          return;
        }
        final script = await repositoryFixture('picacg');
        final prelude = await rootBundle.loadString('assets/js/runtime.js');
        final service = ExtensionService(
          meta: ExtensionMeta.parse(script)!,
          script: script,
          prelude: prelude,
        );
        await service.init();
        try {
          final favorites = Storage.favorites()
              .where((item) => item.package == 'picacg')
              .toList();
          final works = favorites.isNotEmpty
              ? favorites
              : await service.latest(1);
          expect(works, isNotEmpty);
          final work = works.first;
          final page = await service.comments(work.url, '${work.url}/1', 1);
          expect(
            page.comments.map((c) => c.key).toSet().length,
            page.comments.length,
          );
          print(
            'PICACG_LIVE_SUCCESS: ${page.comments.length} 条评论，总计 ${page.total} 条。',
          );
          final withReplies = page.comments.where(
            (comment) => comment.replyCount > 0 && !comment.hidden,
          );
          if (withReplies.isNotEmpty) {
            final replies = await service.comments(
              work.url,
              '${work.url}/1',
              1,
              parentId: withReplies.first.id,
            );
            print('PICACG_REPLIES_SUCCESS: ${replies.comments.length} 条回复。');
          }
        } finally {
          service.dispose();
        }
      });
      await tester.pump();
    },
    skip: Platform.environment['FUSION_VERIFY_PICACG_ACCOUNT'] != '1',
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
