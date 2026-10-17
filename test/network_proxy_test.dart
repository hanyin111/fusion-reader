import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/danmaku.dart';
import 'package:fusion_reader/services/danmaku_service.dart';
import 'package:fusion_reader/services/image_loader.dart';
import 'package:fusion_reader/services/network.dart';
import 'package:fusion_reader/services/proxy_resolver.dart';

void main() {
  late HttpServer origin;
  late HttpServer proxy;
  late String proxyAddress;
  final directRequests = <Uri>[];
  final proxyRequests = <String>[];
  var reads = 0;

  String registry({bool enabled = true}) =>
      '''
HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings
    ProxyEnable    REG_DWORD    ${enabled ? '0x1' : '0x0'}
    ProxyServer    REG_SZ    $proxyAddress
''';

  setUp(() async {
    directRequests.clear();
    proxyRequests.clear();
    reads = 0;
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) async {
      directRequests.add(request.uri);
      request.response.write('direct');
      await request.response.close();
    });
    proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    proxyAddress = '127.0.0.1:${proxy.port}';
    proxy.listen((request) async {
      proxyRequests.add('${request.method} ${request.uri}');
      if (request.method == 'CONNECT') {
        request.response.statusCode = HttpStatus.badGateway;
      } else if (request.uri.path == '/comments.xml') {
        request.response.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
        request.response.write(
          '<i><d p="1,1,25,16777215,0,0,0,0">代理弹幕</d></i>',
        );
      } else if (request.uri.path == '/cover') {
        request.response.add([1, 2, 3, 4]);
      } else {
        request.response.headers.contentType = ContentType.text;
        request.response.write('proxied');
      }
      await request.response.close();
    });
    Network.declaredModes.clear();
    Network.setProxyResolverForTesting(
      SystemProxyResolver(
        environment: {},
        loadSettings: () async {
          reads++;
          // Real requests must wait for discovery, even when no env proxy exists.
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return SystemProxySettings.fromWindowsRegistry(registry());
        },
      ),
    );
  });

  tearDown(() async {
    Network.setProxyResolverForTesting(null);
    Network.declaredModes.clear();
    await origin.close(force: true);
    await proxy.close(force: true);
  });

  String url(String path) => 'http://127.0.0.1:${origin.port}$path';

  test(
    'first concurrent source requests use Windows proxy without env variables',
    () async {
      final results = await Future.wait(
        List.generate(
          3,
          (index) =>
              Network.forPackage('fixture').get<String>(url('/chapter/$index')),
        ),
      );
      expect(results.map((response) => response.data), everyElement('proxied'));
      expect(proxyRequests, hasLength(3));
      expect(directRequests, isEmpty);
      expect(reads, 1);
    },
  );

  test(
    'explicit direct and request overrides retain their intended routing',
    () async {
      Network.declaredModes['fixture'] = NetMode.direct;
      final direct = await Network.forPackage(
        'fixture',
      ).get<String>(url('/direct'));
      expect(direct.data, 'direct');
      expect(reads, 0);
      final forced = await Network.forPackage(
        'fixture',
        override: 'proxy',
      ).get<String>(url('/proxy'));
      expect(forced.data, 'proxied');
      final auto = await Network.forPackage(
        'fixture',
        override: 'auto',
      ).get<String>(url('/auto'));
      expect(auto.data, 'proxied');
      expect(Network.usesProxyFor('fixture', override: 'auto'), isTrue);
      expect(directRequests, hasLength(1));
      expect(proxyRequests, hasLength(2));
    },
  );

  test('HTTPS requests attempt CONNECT through the selected proxy', () async {
    await expectLater(
      Network.forPackage(
        'fixture',
      ).get<String>('https://source.example.invalid/chapter'),
      throwsA(isA<DioException>()),
    );
    // The local proxy deliberately rejects the tunnel; no TLS validation is disabled.
    expect(
      proxyRequests.single,
      startsWith('CONNECT source.example.invalid:443'),
    );
    expect(directRequests, isEmpty);
  });

  test(
    'covers and danmaku use the same system route as plugin requests',
    () async {
      final cover = await SourceImageCache.fetchBytes('fixture', url('/cover'));
      expect(cover, [1, 2, 3, 4]);
      final comments = await DanmakuService.load(
        'fixture',
        DanmakuSource(url: url('/comments.xml'), format: 'bilibili'),
      );
      expect(comments.single.text, '代理弹幕');
      expect(proxyRequests, hasLength(2));
      expect(directRequests, isEmpty);
    },
  );

  test(
    'proxy toggles are observed by an existing client after refresh',
    () async {
      var enabled = true;
      Network.setProxyResolverForTesting(
        SystemProxyResolver(
          environment: {},
          refreshInterval: Duration.zero,
          loadSettings: () async => SystemProxySettings.fromWindowsRegistry(
            registry(enabled: enabled),
          ),
        ),
      );
      final client = Network.forPackage('fixture');
      expect((await client.get<String>(url('/first'))).data, 'proxied');
      enabled = false;
      expect((await client.get<String>(url('/second'))).data, 'direct');
      enabled = true;
      expect((await client.get<String>(url('/third'))).data, 'proxied');
      expect(proxyRequests, hasLength(2));
      expect(directRequests, hasLength(1));
    },
  );

  test(
    'manual native settings route socket requests without environment variables',
    () async {
      Network.setProxyResolverForTesting(
        SystemProxyResolver(
          environment: {},
          loadSettings: () async => SystemProxySettings.fromMap({
            'http': proxyAddress,
            'https': proxyAddress,
            'bypass': <String>[],
          }),
        ),
      );
      expect(
        (await Network.forPackage('fixture').get<String>(url('/ios'))).data,
        'proxied',
      );
      await Network.prepare();
      expect(
        Network.resolvedProxy(
          uri: Uri.parse('https://media.example.test/video'),
        ),
        proxyAddress,
      );
      expect(proxyRequests, hasLength(1));
      expect(directRequests, isEmpty);
    },
  );

  test(
    'system exclusions and per-protocol proxy addresses are respected',
    () async {
      final resolver = SystemProxyResolver(
        environment: {},
        loadSettings: () async => SystemProxySettings.fromWindowsRegistry('''
ProxyEnable REG_DWORD 0x1
ProxyServer REG_SZ http=127.0.0.1:7890;https=[::1]:7891
ProxyOverride REG_SZ <local>;127.*;*.internal.test
'''),
      );
      await resolver.refresh();
      expect(
        resolver.findProxy(Uri.parse('http://external.test')),
        'PROXY 127.0.0.1:7890',
      );
      expect(
        resolver.findProxy(Uri.parse('https://external.test')),
        'PROXY [::1]:7891',
      );
      for (final host in ['localhost', '127.0.0.1', 'reader.internal.test']) {
        expect(resolver.findProxy(Uri.parse('https://$host')), 'DIRECT');
      }
    },
  );

  test(
    'explicit environment proxy keeps priority and NO_PROXY is respected',
    () async {
      final resolver = SystemProxyResolver(
        environment: {
          'HTTPS_PROXY': 'http://127.0.0.1:8900/',
          'NO_PROXY': '.local.test',
        },
        loadSettings: () async =>
            const SystemProxySettings(https: '127.0.0.1:7800'),
      );
      await resolver.refresh();
      expect(
        resolver.findProxy(Uri.parse('https://external.test')),
        'PROXY 127.0.0.1:8900',
      );
      expect(
        resolver.findProxy(Uri.parse('https://reader.local.test')),
        'DIRECT',
      );
    },
  );

  test(
    'unavailable system settings retain ordinary direct networking',
    () async {
      Network.setProxyResolverForTesting(
        SystemProxyResolver(
          environment: {},
          loadSettings: () async => throw StateError('unavailable'),
        ),
      );
      expect(
        (await Network.forPackage(
          'fixture',
        ).get<String>(url('/offline-settings'))).data,
        'direct',
      );
      expect(proxyRequests, isEmpty);
    },
  );
}
