// Probes the ESJ Zone login by loading the member-only favorites channel.
//
// The favorites page is served only to a live session, so it separates the
// three failure modes that all look like "login doesn't work" from the UI:
// wrong credentials (site rejects the POST), a cookie that is not kept
// (login succeeds but the member area still bounces), and a parser problem
// (logged in fine but the list comes back empty).
//
// Requires the user's own ESJ Zone credentials to be saved in the app
// (扩展 -> ESJ Zone -> 设置); the test skips when they are absent.
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/services/extension_manager.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('favorites channel proves the ESJ Zone login', (tester) async {
    await tester.runAsync(() async {
      await Storage.init();
      await ExtensionManager.instance.init();

      final service = ExtensionManager.instance.byPackage('esjzone');
      expect(service, isNotNull, reason: 'esjzone 扩展未加载');

      final email = Storage.extSetting('esjzone', 'email');
      final password = Storage.extSetting('esjzone', 'password');
      if (email == null ||
          (email as String).isEmpty ||
          password == null ||
          (password as String).isEmpty) {
        print('\n===== 跳过：应用内未保存 ESJ Zone 账号密码 =====');
        markTestSkipped('ESJ Zone credentials not configured in the app');
        return;
      }
      print('\n===== ESJ 账号: ${email.replaceRange(2, email.indexOf('@'), '***')} =====');

      final channels = await service!.channels();
      print('channels: ${channels.map((c) => '${c.title}(${c.key})').join(', ')}');
      final fav = channels.where((c) => c.key == 'favorites').toList();
      expect(fav, isNotEmpty, reason: 'esjzone 未发布「我的收藏」频道');

      final items = await service.latest(1, channel: 'favorites');
      print('我的收藏: ${items.length} 条');
      for (final it in items.take(10)) {
        print('  - ${it.title}  ${it.url}');
      }
      expect(items, isNotEmpty,
          reason: '登录后收藏列表为空：若账号确有收藏，说明登录或解析仍有问题');
    });
  }, timeout: const Timeout(Duration(minutes: 6)));
}
