import 'repository_fixture.dart';
// Verifies the PicACG signing chain end-to-end inside the real runtime.
//
// A full content check needs a Picacomic account, which only the user can
// create. What is checkable without one: that the HMAC signature, timestamp
// and header set are accepted by the server — a bad signature or clock is
// rejected with a *different* error than bad credentials.
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/services/extension_manager.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'picacg signing chain is accepted by the server',
    (tester) async {
      await tester.runAsync(() async {
        await Storage.init();
        await ExtensionManager.instance.init();
        await installRepositoryFixtures(['picacg']);

        final service = ExtensionManager.instance.byPackage('picacg');
        expect(service, isNotNull, reason: 'picacg 扩展未加载');

        // Ensure no real credentials leak into this probe.
        await Storage.setExtSetting('picacg', '__token', '');
        await Storage.setExtSetting(
          'picacg',
          'email',
          'fusionreader_probe_account',
        );
        await Storage.setExtSetting(
          'picacg',
          'password',
          'not-a-real-password',
        );

        String message;
        try {
          final items = await service!.latest(1);
          message = 'UNEXPECTED-SUCCESS: 返回 ${items.length} 条（该帐号竟然有效？）';
        } catch (e) {
          message = e.toString();
        }
        print(
          '\n===== PICACG AUTH PROBE =====\n$message\n=============================',
        );

        final lower = message.toLowerCase();
        // These would mean our own request construction is broken.
        expect(
          lower.contains('1029'),
          isFalse,
          reason: '时间戳不同步，签名时间取值有误: $message',
        );
        expect(
          lower.contains('not synchronize'),
          isFalse,
          reason: '时间戳不同步: $message',
        );
        expect(lower.contains('1027'), isFalse, reason: '签名错误: $message');
        expect(lower.contains('signature'), isFalse, reason: '签名被拒: $message');

        // What we expect instead: the server processed the signed request and
        // turned us down on the credentials (or rate-limited the probe).
        final credentialRejection =
            lower.contains('1004') ||
            lower.contains('1005') ||
            lower.contains('1023') ||
            lower.contains('invalid email') ||
            lower.contains('登录失败') ||
            lower.contains('too many requests');
        expect(
          credentialRejection,
          isTrue,
          reason: '预期服务端因帐号无效而拒绝，实际返回: $message',
        );
      });
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
