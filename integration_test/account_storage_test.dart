import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/services/account_api.dart';
import 'package:fusion_reader/services/account_service.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native secure storage survives recreation and clears only its test key',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Account storage test'))),
      );
      final key =
          'fusion_storage_test_${DateTime.now().microsecondsSinceEpoch}';
      const url = 'https://fixture.invalid';
      final store = SecureAccountSessionStore(url, key: key);
      final session = AccountSession(
        userId: 'fixture',
        username: 'fixture',
        token: 'abcdefghijklmnopqrstuvwxyz0123456789_ABCD',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
      );
      await tester.runAsync(() async {
        try {
          expect(await store.read(), isNull);
          await store.write(session);
          final restored = await SecureAccountSessionStore(
            url,
            key: key,
          ).read();
          expect(restored!.token, session.token);
          expect(
            await SecureAccountSessionStore(
              'https://other.invalid',
              key: key,
            ).read(),
            isNull,
          );
          await store.clear();
          expect(await store.read(), isNull);
        } finally {
          await store.clear();
        }
      });
    },
  );
}
