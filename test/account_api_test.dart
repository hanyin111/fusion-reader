import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/services/account_api.dart';
import 'package:fusion_reader/services/account_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'account_service_test.dart' show loginSession, snapshot;

class FixtureAdapter implements HttpClientAdapter {
  int status = 200;
  dynamic response = {};
  RequestOptions? request;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    return ResponseBody.fromString(
      jsonEncode(response),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FixtureAdapter adapter;
  late HttpAccountApi api;
  setUp(() {
    adapter = FixtureAdapter();
    api = HttpAccountApi(
      baseUrl: 'https://sync.example.test/',
      dio: Dio()..httpClientAdapter = adapter,
    );
  });
  test('production requires HTTPS without credentials, query, or fragment', () {
    for (final url in [
      '',
      'http://example.com',
      'https://u:p@example.com',
      'https://example.com?token=x',
      'https://example.com#x',
    ]) {
      expect(HttpAccountApi(baseUrl: url).configured, isFalse);
    }
    expect(
      HttpAccountApi(
        baseUrl: 'http://127.0.0.1:8000',
        allowLocalHttp: true,
      ).configured,
      isTrue,
    );
    expect(
      HttpAccountApi(
        baseUrl: 'http://example.com',
        allowLocalHttp: true,
      ).configured,
      isFalse,
    );
  });
  test(
    'auth request uses correct endpoint with no redirect or credential in URL',
    () async {
      adapter.response = loginSession().toJson();
      await api.authenticate('reader', 'password123', activationCode: 'INVITE');
      expect(
        adapter.request!.uri.toString(),
        'https://sync.example.test/v1/auth/register',
      );
      expect(adapter.request!.data, {
        'username': 'reader',
        'password': 'password123',
        'activationCode': 'INVITE',
      });
      expect(adapter.request!.followRedirects, isFalse);
    },
  );
  test(
    'login errors are safe messages and are distinct from expired bearer sessions',
    () async {
      adapter.status = 401;
      adapter.response = {
        'error': 'invalid_credentials',
        'detail': 'secret internal password value',
      };
      await expectLater(
        api.authenticate('reader', 'password123'),
        throwsA(
          isA<AccountException>()
              .having((e) => e.expired, 'expired', isFalse)
              .having((e) => e.message, 'message', '用户名或密码不正确。'),
        ),
      );
      await expectLater(
        api.download(loginSession().token),
        throwsA(
          isA<AccountException>().having((e) => e.expired, 'expired', isTrue),
        ),
      );
      adapter.status = 403;
      adapter.response = {'error': 'invalid_activation_code'};
      await expectLater(
        api.authenticate('reader', 'password123', activationCode: 'OLD'),
        throwsA(
          isA<AccountException>().having(
            (e) => e.message,
            'message',
            contains('激活码'),
          ),
        ),
      );
    },
  );
  test(
    'revision and entire cloud snapshot are checked before returning',
    () async {
      adapter.response = {
        'revision': 4,
        'snapshot': jsonDecode(snapshot().encode()),
      };
      expect((await api.download(loginSession().token)).revision, 4);
      expect(
        adapter.request!.headers['Authorization'],
        'Bearer ${loginSession().token}',
      );
      for (final broken in [
        {'revision': -1, 'snapshot': jsonDecode(snapshot().encode())},
        {
          'revision': 1,
          'snapshot': {'favorites': []},
        },
        {'revision': 2, 'snapshot': null},
      ]) {
        adapter.response = broken;
        await expectLater(
          api.download(loginSession().token),
          throwsA(isA<AccountException>()),
        );
      }
      adapter.status = 409;
      await expectLater(
        api.upload(loginSession().token, 4, snapshot()),
        throwsA(
          isA<AccountException>().having((e) => e.conflict, 'conflict', isTrue),
        ),
      );
    },
  );
  test(
    'saved tokens restore only for the same service and passwords are never persisted',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final store = SecureAccountSessionStore('https://sync.example.test');
      await store.write(loginSession());
      expect((await store.read())!.username, 'reader');
      expect(
        await SecureAccountSessionStore('https://other.example.test').read(),
        isNull,
      );
      final raw = await const FlutterSecureStorage().read(
        key: 'fusion_account_session_v1',
      );
      expect(raw, isNot(contains('password')));
      expect(raw, isNot(contains('activationCode')));
      await store.clear();
      expect(await store.read(), isNull);
    },
  );
}
