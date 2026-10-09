import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/pages/account_page.dart';
import 'package:fusion_reader/services/account_service.dart';

import 'account_service_test.dart'
    show MemoryApi, MemoryLibrary, MemorySessions;

void main() {
  testWidgets(
    'register form requires matching password and activation code before login',
    (tester) async {
      final api = MemoryApi();
      final service = AccountService(
        api: api,
        sessions: MemorySessions(),
        library: MemoryLibrary(),
      );
      await tester.pumpWidget(MaterialApp(home: AccountPage(service: service)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('激活码注册'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(0), 'reader');
      await tester.enterText(find.byType(TextFormField).at(1), 'password123');
      await tester.enterText(find.byType(TextFormField).at(2), 'different');
      await tester.ensureVisible(find.text('注册并登录'));
      await tester.tap(find.text('注册并登录'));
      await tester.pumpAndSettle();
      expect(find.text('两次输入的密码不一致'), findsOneWidget);
      expect(api.logins, 0);
      await tester.enterText(find.byType(TextFormField).at(2), 'password123');
      await tester.enterText(find.byType(TextFormField).at(3), 'INVITE');
      await tester.ensureVisible(find.text('注册并登录'));
      await tester.tap(find.text('注册并登录'));
      await tester.pumpAndSettle();
      expect(find.text('已登录'), findsOneWidget);
      expect(api.activation, 'INVITE');
      await tester.tap(find.text('本地同步云端'));
      await tester.pumpAndSettle();
      expect(api.uploads, 0);
      expect(find.textContaining('覆盖云端'), findsOneWidget);
      await tester.tap(find.text('确认上传'));
      await tester.pumpAndSettle();
      expect(api.uploads, 1);
      expect(find.text('本机数据已上传，云端已替换'), findsOneWidget);
      await tester.ensureVisible(find.text('云端同步本地'));
      await tester.tap(find.text('云端同步本地'));
      await tester.pumpAndSettle();
      expect(find.textContaining('覆盖本机'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(api.uploads, 1);
      await tester.ensureVisible(find.text('退出登录'));
      await tester.tap(find.text('退出登录'));
      await tester.pumpAndSettle();
      expect(find.text('用户名'), findsOneWidget);
      expect(service.session, isNull);
      await tester.pumpWidget(const SizedBox());
      service.dispose();
    },
  );
  testWidgets('unconfigured builds explain service state and cannot submit', (
    tester,
  ) async {
    final api = MemoryApi()..configured = false;
    final service = AccountService(
      api: api,
      sessions: MemorySessions(),
      library: MemoryLibrary(),
    );
    await tester.pumpWidget(MaterialApp(home: AccountPage(service: service)));
    await tester.pumpAndSettle();
    expect(find.textContaining('同步服务尚未部署'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(api.logins, 0);
    await tester.pumpWidget(const SizedBox());
    service.dispose();
  });
}
