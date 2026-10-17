import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:fusion_reader/services/apple_http_adapter.dart';
import 'package:fusion_reader/services/network.dart';
import 'package:fusion_reader/services/proxy_resolver.dart';
import 'package:fusion_reader/services/system_proxy.dart';

import '../test/support/http_transport_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'iOS system proxy bridge is registered on the real Flutter engine',
    (tester) async {
      if (!Platform.isIOS) return;
      final settings = await SystemProxyResolver.channel
          .invokeMapMethod<String, dynamic>('settings')
          .timeout(const Duration(seconds: 10));
      expect(settings, isNotNull);
      expect(settings!['http'], isA<String>());
      expect(settings['https'], isA<String>());
      expect(settings['bypass'], isA<List>());
      final resolver = SystemProxyResolver(environment: {});
      await resolver.refresh();
      expect(resolver.findProxy(Uri.parse('file:///local-book')), 'DIRECT');
    },
  );

  testWidgets(
    'iOS requests really use URLSession for text, cookies, redirects and streaming',
    (tester) async {
      if (!Platform.isIOS) return;
      final fixture = await HttpTransportFixture.start();
      addTearDown(fixture.close);
      addTearDown(Network.reload);
      final dio = Network.forPackage('transport_fixture');
      expect(dio.httpClientAdapter, isA<AppleHttpAdapter>());
      expect(
        Network.forPackage(
          'transport_fixture',
          override: 'direct',
        ).httpClientAdapter,
        isNot(isA<AppleHttpAdapter>()),
      );
      final updater = Dio();
      addTearDown(() => updater.close(force: true));
      await configureSystemProxy(updater);
      expect(updater.httpClientAdapter, isA<AppleHttpAdapter>());

      await tester.runAsync(() async {
        final echo = await dio.post<Map<String, dynamic>>(
          fixture.url('/echo'),
          data: 'native upload',
          options: Options(headers: {'User-Agent': 'Native-Fixture'}),
        );
        expect(echo.data!['body'], 'native upload');
        expect(echo.data!['userAgent'], 'Native-Fixture');
        await dio.get<String>(fixture.url('/cookies'));
        final cookies = await dio.get<Map<String, dynamic>>(
          fixture.url('/echo'),
        );
        expect(cookies.data!['cookie'], contains('first=one'));
        expect(cookies.data!['cookie'], contains('second=two'));
        final stopped = await dio.get<String>(
          fixture.url('/redirect'),
          options: Options(followRedirects: false, validateStatus: (_) => true),
        );
        expect(stopped.statusCode, 302);
        expect(fixture.paths, isNot(contains('/target')));
        expect(
          (await dio.get<String>(fixture.url('/redirect'))).data,
          'redirected',
        );
        final bytes = await dio.get<List<int>>(
          fixture.url('/bytes'),
          options: Options(responseType: ResponseType.bytes),
        );
        expect(bytes.data, [0, 1, 2, 255]);
        final streaming = await dio.get<ResponseBody>(
          fixture.url('/stream'),
          options: Options(responseType: ResponseType.stream),
        );
        expect(
          await streaming.data!.stream.first.timeout(
            const Duration(seconds: 5),
          ),
          [1, 2, 3],
        );
        expect(fixture.release.isCompleted, isFalse);
        final token = CancelToken();
        final pending = dio.get<String>(
          fixture.url('/slow'),
          cancelToken: token,
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
        token.cancel();
        await assertion.timeout(const Duration(seconds: 5));
        expect(
          (await dio.get<String>(fixture.url('/target'))).data,
          'redirected',
        );
      });
    },
  );
}
