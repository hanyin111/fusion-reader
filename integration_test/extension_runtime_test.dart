import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/pages/explore_page.dart';
import 'package:fusion_reader/services/extension_manager.dart';
import 'package:fusion_reader/services/extension_runtime.dart';
import 'package:fusion_reader/services/network.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'linovelib_test.dart' show isolateLinovelibTestStorage;

String fixture(String package, String name, String baseUrl) =>
    '''
// ==MiruExtension==
// @name $name
// @package $package
// @type novel
// @webSite $baseUrl
// @network direct
// @comments chapter
// ==/MiruExtension==
export default class extends Extension {
  loads = 0;
  async load() {
    await this.registerSetting({key:'marker',defaultValue:this.package});
    await this.sleep(5);
    this.loads++;
  }
  async channels() { await this.sleep(5); return []; }
  async latest(page) {
    const marker = await this.getSetting('marker');
    const html = await this.request('/' + this.package);
    const el = await this.querySelector(html, '.title');
    const digest = await this.md5(marker);
    if (digest.length !== 32) throw new Error('hash bridge failed');
    return [{title:await el.text,url:'/' + marker + '/' + page}];
  }
  async search(keyword, page) {
    if (keyword === 'fail') throw new Error('可读的脚本错误');
    const html = await this.request('/' + this.package + '?q=' + encodeURIComponent(keyword));
    const el = await this.querySelector(html, '.title');
    return [{title:await el.text,url:'/' + this.package + '/search/' + page}];
  }
  async detail(url) { return {title:this.package,desc:String(this.loads),episodes:[]}; }
  async watch(url) { return {content:['中文 "引号" 🌸','{"ok":false,"error":"只是正文"}']}; }
  async comments(work, chapter, page, parent) {
    await this.sleep(5);
    return {comments:[{id:this.package,username:'读者',text:chapter}],hasMore:false};
  }
}
''';

Future<void> waitForText(WidgetTester tester, String text) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (find.text(text).evaluate().isEmpty) {
    if (DateTime.now().isAfter(deadline)) fail('Browse never displayed: $text');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
  }
  expect(find.byType(GridView), findsOneWidget);
}

void main() {
  isolateLinovelibTestStorage();
  testWidgets(
    'all sources load, and multiple JS contexts browse/search independently',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('脚本兼容性检查'))),
      );
      final manager = ExtensionManager.instance;
      late HttpServer server;
      late ExtensionService first;
      late ExtensionService second;
      await tester.runAsync(() async {
        await Storage.init();
        await manager.init();
        expect(manager.all.length, ExtensionManager.bundledPackages.length);
        expect(manager.loadErrors, isEmpty);
        expect(manager.all.every((service) => service.loaded), isTrue);
        for (final package in ExtensionManager.bundledPackages) {
          await manager.setDisabled(package, true);
        }

        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          final package = request.uri.path.substring(1);
          final name = package == 'runtime_alpha' ? '运行测试甲' : '运行测试乙';
          final query = request.uri.queryParameters['q'] ?? '正文';
          request.response.headers.contentType = ContentType.html;
          request.response.write('<h1 class="title">$name $query</h1>');
          await request.response.close();
        });
        final url = 'http://127.0.0.1:${server.port}';
        await manager.installFromScript(fixture('runtime_alpha', '运行测试甲', url));
        await manager.installFromScript(fixture('runtime_beta', '运行测试乙', url));
        first = manager.byPackage('runtime_alpha')!;
        second = manager.byPackage('runtime_beta')!;
        final lists = await Future.wait([first.latest(1), second.latest(2)]);
        expect(lists[0].single.url, '/runtime_alpha/1');
        expect(lists[1].single.url, '/runtime_beta/2');
        expect(lists[0].single.title, '运行测试甲 正文');
        expect(lists[1].single.title, '运行测试乙 正文');
        expect((await first.detail('/work')).desc, '1');
        expect((await first.watch('/chapter'))['content'], [
          '中文 "引号" 🌸',
          '{"ok":false,"error":"只是正文"}',
        ]);
        expect(
          (await second.comments(
            '/work',
            '/chapter/2',
            1,
          )).comments.single.text,
          '/chapter/2',
        );
        await expectLater(
          first.search('fail', 1),
          throwsA(
            isA<ExtensionException>().having(
              (e) => e.message,
              'message',
              contains('可读的脚本错误'),
            ),
          ),
        );

        await manager.reload('runtime_alpha');
        expect((await first.latest(3)).single.url, '/runtime_alpha/3');
        expect((await second.latest(4)).single.url, '/runtime_beta/4');

        // A failed initialization must be retryable, and simultaneous callers
        // must wait for the same load instead of using a half-initialized context.
        final retryScript = fixture('runtime_retry', '重试测试', url).replaceFirst(
          'this.loads++;',
          "const attempt = (await this.getSetting('attempt') || 0) + 1;"
              "await this.setSetting('attempt', attempt);"
              "if (attempt === 1) throw new Error('首次加载失败'); this.loads++;",
        );
        final retry = ExtensionService(
          meta: ExtensionMeta.parse(retryScript)!,
          script: retryScript,
          prelude: await rootBundle.loadString('assets/js/runtime.js'),
        );
        try {
          await expectLater(retry.init(), throwsA(isA<ExtensionException>()));
          expect(retry.loaded, isFalse);
          await Future.wait([retry.init(), retry.init(), retry.init()]);
          expect(retry.loaded, isTrue);
          expect(Storage.extSetting('runtime_retry', 'attempt'), 2);
          expect((await retry.detail('/work')).desc, '1');
        } finally {
          retry.dispose();
        }
        // The newest context has been released; the older ones must still work.
        expect((await second.latest(5)).single.url, '/runtime_beta/5');
      });

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ExploreTab(type: MediaType.novel)),
        ),
      );
      await tester.pump();
    final initial = manager.byType(MediaType.novel).first.meta.name;
    await waitForText(tester, '$initial 正文');
    await tester.tap(find.widgetWithText(ChoiceChip, '运行测试甲'));
    await tester.pump();
    await waitForText(tester, '运行测试甲 正文');
      await tester.tap(find.widgetWithText(ChoiceChip, '运行测试乙'));
      await tester.pump();
      await waitForText(tester, '运行测试乙 正文');
      await tester.enterText(find.byType(TextField), '查询');
      tester.widget<SearchBar>(find.byType(SearchBar)).onSubmitted!('查询');
      await tester.pump();
      await waitForText(tester, '运行测试乙 查询');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        first.dispose();
        second.dispose();
        await server.close(force: true);
        Network.reload();
        await Hive.close();
      });
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
