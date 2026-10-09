import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/services/extension_manager.dart';
import 'package:fusion_reader/services/extension_runtime.dart';
import 'package:fusion_reader/services/image_loader.dart';
import 'package:fusion_reader/services/network.dart';
import 'package:fusion_reader/services/offline_cache.dart';
import 'package:fusion_reader/services/sources.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';

class _Paths extends PathProviderPlatform {
  final Directory root;
  _Paths(this.root);
  Future<String?> directory(String name) async =>
      (await Directory('${root.path}/$name').create(recursive: true)).path;
  @override
  Future<String?> getApplicationDocumentsPath() => directory('documents');
  @override
  Future<String?> getApplicationSupportPath() => directory('support');
  @override
  Future<String?> getTemporaryPath() => directory('temp');
  @override
  Future<String?> getApplicationCachePath() => directory('cache');
}

String encryptJson(Object value, String secret) {
  final key = Uint8List.fromList(
    utf8.encode(md5.convert(utf8.encode(secret)).toString()),
  );
  final plain = utf8.encode(jsonEncode(value));
  final padding = 16 - plain.length % 16;
  final padded = Uint8List.fromList([
    ...plain,
    ...List.filled(padding, padding),
  ]);
  final output = Uint8List(padded.length);
  final aes = AESEngine()..init(true, KeyParameter(key));
  for (var offset = 0; offset < padded.length; offset += 16) {
    aes.processBlock(padded, offset, output, offset);
  }
  return base64Encode(output);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final root = Directory.systemTemp.createTempSync('fusion_jmcomic_');
  final previousPaths = PathProviderPlatform.instance;
  PathProviderPlatform.instance = _Paths(root);

  tearDownAll(() async {
    for (final service in ExtensionManager.instance.all) {
      service.dispose();
    }
    Network.reload();
    await Hive.close();
    PathProviderPlatform.instance = previousPaths;
    await root.delete(recursive: true);
  });

  testWidgets(
    'native plugin API, domain fallback, image cache and offline pages',
    (tester) async {
      await tester.runAsync(() async {
        await Storage.init();
        await ExtensionManager.instance.init();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final base = 'http://127.0.0.1:${server.port}';
        final source = img.Image(width: 3, height: 23);
        for (var y = 0; y < source.height; y++) {
          for (var x = 0; x < source.width; x++) {
            source.setPixelRgb(x, y, y, x, 42);
          }
        }
        final scrambled = img.encodePng(source);
        var discoveryCalls = 0;
        var brokenCalls = 0;
        var settingCalls = 0;
        var searchCalls = 0;
        String? searchQuery;
        final failures = <String>[];
        server.listen((request) async {
          try {
            if (request.uri.path == '/domains') {
              discoveryCalls++;
              request.response.write(
                encryptJson({
                  'Server': ['broken.invalid', 'good.invalid'],
                }, 'diosfjckwpqpdfjkvnqQjsik'),
              );
            } else if (request.uri.path.startsWith('/media/photos/')) {
              expect(request.headers.value('referer'), 'https://localhost/');
              expect(request.headers.value('user-agent'), contains('Mobile'));
              expect(request.uri.fragment, isEmpty);
              request.response.headers.contentType = ContentType(
                'image',
                'png',
              );
              request.response.add(scrambled);
            } else if (request.uri.path == '/slow') {
              // Request deadline includes a server that never sends a body.
              await Future<void>.delayed(const Duration(seconds: 3));
              request.response.write('{}');
            } else {
              final ts = request.headers.value('tokenparam')!.split(',').first;
              expect(
                request.headers.value('token'),
                md5.convert(utf8.encode('${ts}18comicAPPContent')).toString(),
              );
              expect(request.headers.value('origin'), 'https://localhost');
              expect(request.headers.value('referer'), 'https://localhost/');
              expect(
                request.headers.value('x-requested-with'),
                'com.example.app',
              );
              expect(request.headers.value('user-agent'), contains('Mobile'));
              if (request.headers.value('x-fixture-host') == 'broken.invalid') {
                brokenCalls++;
                request.response.statusCode = 503;
                request.response.write('fixture unavailable');
              } else {
                Object data;
                switch (request.uri.path) {
                  case '/setting':
                    settingCalls++;
                    data = {'img_host': 'https://cdn.fixture.invalid'};
                  case '/categories/filter':
                    data = {
                      'total': '2',
                      'content': [
                        {'id': 41, 'name': '接口测试漫画', 'author': '测试作者'},
                        {'id': '42', 'name': '独立章节'},
                      ],
                    };
                  case '/search':
                    searchCalls++;
                    searchQuery = request.uri.queryParameters['search_query'];
                    data = {
                      'total': 1,
                      'list': [
                        {'id': '41', 'name': '搜索测试'},
                      ],
                    };
                  case '/album':
                    data = {
                      'name': '接口测试漫画',
                      'author': ['测试作者', '第二作者', '测试作者'],
                      'description': '仅用于接口验证',
                      'tags': ['测试'],
                      'series': request.uri.queryParameters['id'] == '42'
                          ? []
                          : [
                              {'id': '220981', 'name': '第二话', 'sort': '2'},
                              {'id': 220980, 'name': '第一话', 'sort': 1},
                            ],
                    };
                  case '/chapter':
                    data = {
                      'id': '220980',
                      'images': ['00001.png', '/invalid.jpg'],
                    };
                  default:
                    throw StateError('Unexpected request: ${request.uri}');
                }
                request.response.headers.contentType = ContentType.json;
                request.response.write(
                  jsonEncode({
                    'code': 200,
                    'data': encryptJson(data, '${ts}185Hcomic3PAPP7R'),
                  }),
                );
              }
            }
          } catch (error) {
            failures.add(error.toString());
            request.response.statusCode = 500;
          } finally {
            await request.response.close();
          }
        });
        final original = await rootBundle.loadString(
          'assets/extensions/jmcomic.js',
        );
        final script =
            '''
$original
const originalWatch = __ExtClass.prototype.watch;
const originalSearch = __ExtClass.prototype.search;
__ExtClass.prototype.search = async function(query, page) {
  if (query === 'timeout-fixture') {
    await this.request('https://good.invalid/slow', {timeoutMs: 1000, retry: false});
    return [];
  }
  return originalSearch.call(this, query, page);
};
__ExtClass.prototype.watch = async function(url) {
  const result = await originalWatch.call(this, url);
  result.netMode = 'direct';
  result.urls = result.urls.map(value => value.replace('https://cdn.fixture.invalid', '$base'));
  return result;
};
__ExtClass.prototype.request = function(url, options) {
  const host = url.match(/^https:\\/\\/([^/]+)/)[1];
  const path = url.includes('/newsvr-2025.txt') ? '/domains' : url.replace(/^https:\\/\\/[^/]+/, '');
  return Extension.prototype.request.call(this, '$base' + path, {
    ...options, netMode: 'direct', headers: { ...options.headers, 'X-Fixture-Host': host }
  });
};
''';
        final manager = ExtensionManager.instance;
        final cache = SourceImageCache.of('jmcomic', netMode: 'direct');
        try {
          await manager.installFromScript(script);
          final service = await manager.ensureLoaded('jmcomic');
          expect((await service.channels()).length, 3);
          final items = await service.latest(1);
          expect(items.map((item) => item.url), ['/album/41', '/album/42']);
          expect(discoveryCalls, 1);
          expect(brokenCalls, 1);
          expect(settingCalls, 1);
          await service.search('测试 &作者', 2);
          expect(searchQuery, '测试 &作者');
          await service.searchAuthor(const MediaAuthor(name: '测试作者'), 1);
          expect(searchQuery, '测试作者');
          expect(searchCalls, 2);
          expect(
            (await service.search(
              'https://18comic.vip/album/41',
              1,
            )).single.url,
            '/album/41',
          );
          final detail = await service.detail(items.first.url);
          expect(detail.authors.map((author) => author.name), ['测试作者', '第二作者']);
          expect(detail.episodes.single.urls.map((chapter) => chapter.url), [
            '/photo/220980',
            '/photo/220981',
          ]);
          expect(
            (await service.detail('/album/42')).episodes.single.urls.single.url,
            '/photo/42',
          );
          final watch = MangaWatch.fromJson(
            await service.watch('/photo/220980'),
          );
          expect(
            watch.urls.single,
            '$base/media/photos/220980/00001.png#fusion-jmcomic=220980',
          );
          final bytes = await SourceImageCache.fetchBytes(
            'jmcomic',
            watch.urls.single,
            netMode: 'direct',
          );
          expect(img.decodeImage(bytes)!.getPixel(0, 0).r, 18);
          final file = await cache.getSingleFile(watch.urls.single);
          expect(file.path, endsWith('.png'));
          expect(
            img.decodeImage(await file.readAsBytes())!.getPixel(0, 22).r,
            1,
          );
          await OfflineCache.instance.download(
            items.first,
            detail.episodes.single.urls.first,
            detail: detail,
          );
          final cached = MangaWatch.fromJson(
            OfflineCache.read('jmcomic', '/photo/220980')!,
          );
          expect(cached.urls.single, isNot(startsWith('http')));
          expect(
            img
                .decodeImage(await File(cached.urls.single).readAsBytes())!
                .getPixel(0, 0)
                .r,
            18,
          );
          expect(
            OfflineCache.readDetail(items.first)!.episodes.single.urls.length,
            2,
          );
          final deadline = Stopwatch()..start();
          await expectLater(
            service.search('timeout-fixture', 1),
            throwsA(isA<ExtensionException>()),
          );
          expect(
            deadline.elapsed,
            lessThan(const Duration(milliseconds: 2500)),
          );
          await manager.setDisabled('jmcomic', true);
          await manager.setDisabled('jmcomic', false);
          expect(manager.loadErrors['jmcomic'], isNull);
          await manager.uninstall('jmcomic');
          expect(
            (await Sources.detail(items.first)).episodes.single.urls.length,
            2,
          );
          expect(
            (await Sources.watchCached(items.first, '/photo/220980'))['urls'],
            cached.urls,
          );
          expect(failures, isEmpty);
        } finally {
          await cache.dispose();
          await server.close(force: true);
        }
      });
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'live anonymous search validates native signing and decryption',
    (tester) async {
      await tester.runAsync(() async {
        await Storage.init();
        await Hive.box('extension_settings').clear();
        final script = await rootBundle.loadString(
          'assets/extensions/jmcomic.js',
        );
        final service = ExtensionService(
          meta: ExtensionMeta.parse(script)!,
          script: script,
          prelude: await rootBundle.loadString('assets/js/runtime.js'),
        );
        try {
          await service.init();
          final items = await service.search(
            'fusion_reader_interface_probe_${DateTime.now().millisecondsSinceEpoch}',
            1,
          );
          expect(items, isEmpty);
        } finally {
          service.dispose();
        }
      });
    },
    skip: !const bool.fromEnvironment('FUSION_JM_LIVE'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
