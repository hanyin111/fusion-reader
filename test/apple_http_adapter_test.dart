import 'dart:convert';
import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart' show CookieJar;
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:fusion_reader/services/apple_http_adapter.dart';

import 'support/http_transport_fixture.dart';

void main() {
  late HttpTransportFixture fixture;
  late Dio dio;
  setUp(() async {
    fixture = await HttpTransportFixture.start();
    dio =
        Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 2),
              receiveTimeout: const Duration(seconds: 2),
            ),
          )
          ..httpClientAdapter = AppleHttpAdapter(
            client: IOClient(HttpClient()..findProxy = (_) => 'DIRECT'),
          )
          ..interceptors.add(CookieManager(CookieJar()));
  });
  tearDown(() async {
    dio.close(force: true);
    await fixture.close();
  });

  test('preserves POST body and custom request headers', () async {
    final response = await dio.post<Map<String, dynamic>>(
      fixture.url('/echo'),
      data: {'value': '中文'},
      options: Options(headers: {'User-Agent': 'Fixture-Mobile'}),
    );
    expect(response.data!['method'], 'POST');
    expect(response.data!['userAgent'], 'Fixture-Mobile');
    expect(jsonDecode(response.data!['body']), {'value': '中文'});
  });

  test('saves both cookies including a cookie with an Expires comma', () async {
    await dio.get<String>(fixture.url('/cookies'));
    final response = await dio.get<Map<String, dynamic>>(fixture.url('/echo'));
    expect(response.data!['cookie'], contains('first=one'));
    expect(response.data!['cookie'], contains('second=two'));
  });

  test('redirect opt-out prevents fetching a different resource', () async {
    final stopped = await dio.get<String>(
      fixture.url('/redirect'),
      options: Options(followRedirects: false, validateStatus: (_) => true),
    );
    expect(stopped.statusCode, 302);
    expect(stopped.headers.value('location'), '/target');
    expect(fixture.paths, ['/redirect']);
    final followed = await dio.get<String>(fixture.url('/redirect'));
    expect(followed.data, 'redirected');
  });

  test('returns binary bytes without text conversion', () async {
    final response = await dio.get<List<int>>(
      fixture.url('/bytes'),
      options: Options(responseType: ResponseType.bytes),
    );
    expect(response.data, [0, 1, 2, 255]);
  });

  test('starts delivering a download before the server finishes', () async {
    final response = await dio.get<ResponseBody>(
      fixture.url('/stream'),
      options: Options(responseType: ResponseType.stream),
    );
    final first = await response.data!.stream.first.timeout(
      const Duration(seconds: 1),
    );
    expect(first, [1, 2, 3]);
    expect(fixture.release.isCompleted, isFalse);
    // Cancelling one response must not close the shared client.
    expect((await dio.get<String>(fixture.url('/target'))).data, 'redirected');
  });

  test(
    'cancels an in-flight request promptly without poisoning the client',
    () async {
      final cancel = CancelToken();
      final pending = dio.get<String>(
        fixture.url('/slow'),
        cancelToken: cancel,
      );
      final assertion = expectLater(
        pending,
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      await fixture.receivedSlowRequest.future;
      cancel.cancel();
      await assertion.timeout(const Duration(seconds: 1));
      expect(
        (await dio.get<String>(fixture.url('/target'))).data,
        'redirected',
      );
    },
  );

  test('receive timeout aborts a stalled download', () async {
    await expectLater(
      dio.get<List<int>>(
        fixture.url('/stream'),
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(milliseconds: 80),
        ),
      ),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.receiveTimeout,
        ),
      ),
    );
  });

  test('force close cancels requests even before headers arrive', () async {
    final pending = dio.get<String>(fixture.url('/slow'));
    final assertion = expectLater(
      pending,
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    await fixture.receivedSlowRequest.future;
    dio.close(force: true);
    await assertion.timeout(const Duration(seconds: 1));
  });
}
