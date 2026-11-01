import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:fusion_reader/models/extension_login.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/pages/extension_login_page.dart';
import 'package:fusion_reader/services/extension_credentials.dart';
import 'package:qr_flutter/qr_flutter.dart';

class _Client implements ExtensionLoginClient {
  int polls = 0, cancels = 0, logouts = 0;
  bool loggedIn = false;
  bool failBegin = false;
  Completer<ExtensionLoginPoll>? pending;
  ExtensionLoginPhase next = ExtensionLoginPhase.waiting;
  @override
  Future<ExtensionLoginStatus> loginStatus() async =>
      ExtensionLoginStatus(loggedIn: loggedIn, username: '测试账号');
  @override
  Future<ExtensionLoginChallenge> beginLogin() async {
    if (failBegin) throw StateError('private-session-value');
    return const ExtensionLoginChallenge(
      qrText: 'https://auth.example/fixture-only',
      message: '请用对应客户端扫码',
    );
  }

  @override
  Future<ExtensionLoginPoll> pollLogin() async {
    polls++;
    return pending?.future ?? ExtensionLoginPoll(next);
  }

  @override
  Future<void> cancelLogin() async {
    cancels++;
  }

  @override
  Future<void> logout() async {
    logouts++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('QR capability is optional and challenge polling is bounded', () {
    const base =
        '// ==MiruExtension==\n// @package fixture\n// @type bangumi\n';
    expect(
      ExtensionMeta.parse('$base// ==/MiruExtension==')!.supportsQrLogin,
      isFalse,
    );
    expect(
      ExtensionMeta.parse(
        '$base// @login qr\n// ==/MiruExtension==',
      )!.supportsQrLogin,
      isTrue,
    );
    final challenge = ExtensionLoginChallenge.fromJson({
      'qrText': 'opaque',
      'pollInterval': 0,
      'expiresIn': 99999,
    });
    expect(challenge.interval, const Duration(seconds: 2));
    expect(challenge.expiresIn, const Duration(minutes: 10));
    expect(
      () => ExtensionLoginChallenge.fromJson({'qrText': 'a' * 4097}),
      throwsFormatException,
    );
    expect(
      () => ExtensionLoginStatus.fromJson({'loggedIn': 'yes'}),
      throwsFormatException,
    );
  });

  test(
    'protected credentials are scoped per source and do not alter app account keys',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'fusion_account_session_v1': 'app-account',
      });
      final store = ExtensionCredentials();
      await store.write('source_one', 'one');
      await store.write('source_two', 'two');
      expect(await store.read('source_one'), 'one');
      await store.clear('source_one');
      expect(await store.read('source_one'), isNull);
      expect(await store.read('source_two'), 'two');
      expect(
        await const FlutterSecureStorage().read(
          key: 'fusion_account_session_v1',
        ),
        'app-account',
      );
      expect(() => store.write('../account', 'x'), throwsFormatException);
      expect(
        () => store.write('source_one', 'x' * 16385),
        throwsFormatException,
      );
      await Future.wait([
        store.write('source_one', 'new'),
        store.clear('source_one'),
      ]);
      expect(await store.read('source_one'), isNull);
    },
  );

  Future<void> open(
    WidgetTester tester,
    _Client client, {
    ValueChanged<bool?>? result,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                final changed = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) =>
                        ExtensionLoginPage(title: '测试来源', client: client),
                  ),
                );
                result?.call(changed);
              },
              child: const Text('打开登录'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开登录'));
    await tester.pumpAndSettle();
  }

  testWidgets('renders QR locally and finishes only after confirmed login', (
    tester,
  ) async {
    final client = _Client();
    bool? changed;
    await open(tester, client, result: (value) => changed = value);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.textContaining('https://auth.example'), findsNothing);
    client.next = ExtensionLoginPhase.scanned;
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('已扫码，请在对应应用中确认'), findsOneWidget);
    expect(changed, isNull);
    client.next = ExtensionLoginPhase.success;
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(changed, isTrue);
    expect(find.byType(ExtensionLoginPage), findsNothing);
  });

  testWidgets(
    'does not overlap polling and stops in background and after closing',
    (tester) async {
      final client = _Client()..pending = Completer<ExtensionLoginPoll>();
      await open(tester, client);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 9));
      expect(client.polls, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      client.pending!.complete(
        const ExtensionLoginPoll(ExtensionLoginPhase.waiting),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      expect(client.polls, 1);
      client.pending = null;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(client.polls, 2);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      final count = client.polls;
      await tester.pump(const Duration(seconds: 9));
      expect(client.polls, count);
      expect(client.cancels, greaterThanOrEqualTo(2));
    },
  );

  testWidgets('expired QR is hidden and failure messages omit private errors', (
    tester,
  ) async {
    final client = _Client()..next = ExtensionLoginPhase.expired;
    await open(tester, client);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('二维码已过期，请刷新'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
    client.failBegin = true;
    await tester.tap(find.text('刷新二维码'));
    await tester.pumpAndSettle();
    expect(find.text('二维码获取失败，请稍后重试'), findsOneWidget);
    expect(find.textContaining('private-session'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('logged-in account can be removed without requesting a QR', (
    tester,
  ) async {
    final client = _Client()..loggedIn = true;
    bool? changed;
    await open(tester, client, result: (value) => changed = value);
    expect(find.text('测试账号'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
    await tester.tap(find.text('退出来源账号'));
    await tester.pumpAndSettle();
    expect(client.logouts, 1);
    expect(changed, isTrue);
  });
}
