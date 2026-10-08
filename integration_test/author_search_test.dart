// Run on Windows to exercise the real QuickJS bridge and navigation together.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/pages/detail_page.dart';
import 'package:fusion_reader/services/extension_manager.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:fusion_reader/widgets/media_card.dart';

import 'linovelib_test.dart' show isolateLinovelibTestStorage;

String fixture(String package, MediaType type, {bool legacy = false}) =>
    '''
// ==MiruExtension==
// @name Author test ${type.name}
// @package $package
// @type ${type.name}
// @webSite https://fixture.example
// ==/MiruExtension==
export default class extends Extension {
  async detail(url) {
    return {title: url === '/current' ? '当前${type.label}' : '其他${type.label}',
      desc: ${jsonEncode(legacy ? '作者：Shelley, Mary\n作品简介' : '作品简介')},
      authors: ${legacy ? '[]' : '[{name:"作者甲",id:"a"},{name:"作者乙",id:"b"}]'}, episodes: []};
  }
  async search(kw, page) {
    ${legacy ? 'if (kw !== "Shelley, Mary") throw new Error("wrong keyword");' : 'throw new Error("must use author query");'}
    return page === 1 ? [{title:'旧插件作品',url:'/legacy'}] : [];
  }
  ${legacy ? '' : '''
  async searchAuthor(author, page) {
    if (!['a', 'b'].includes(author.id)) throw new Error('author ID missing');
    if (page === 1) return [{title:'当前${type.label}',url:'https://fixture.example/current'}];
    if (page === 2) return [{title: author.name + '${type.label}作品',url:'/other-' + author.id}];
    if (page === 3) return [
      {title: author.name + '${type.label}作品',url:'/other-' + author.id},
      {title:'后续${type.label}作品',url:'/later-' + author.id}];
    return [];
  }'''}
}
''';

Future<void> settle(WidgetTester tester) async {
  // QuickJS completes through native messages, outside the test's fake clock.
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 70)),
    );
    await tester.pump(const Duration(milliseconds: 70));
  }
}

void main() {
  isolateLinovelibTestStorage();
  testWidgets(
    'author navigation stays in the work source and supports old scripts',
    (tester) async {
      await tester.runAsync(() async {
        await Storage.init();
        await ExtensionManager.instance.init();
      });
      for (final type in [MediaType.novel, MediaType.manga]) {
        final package = 'author_fixture_${type.name}';
        await tester.runAsync(
          () => ExtensionManager.instance.installFromScript(
            fixture(package, type),
          ),
        );
        final item = MediaItem(
          package: package,
          type: type,
          title: '当前${type.label}',
          url: '/current',
        );
        await tester.pumpWidget(
          MaterialApp(
            key: UniqueKey(),
            home: DetailPage(item: item),
          ),
        );
        await settle(tester);
        expect(find.widgetWithText(TextButton, '作者甲'), findsOneWidget);
        expect(find.widgetWithText(TextButton, '作者乙'), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, '作者甲'));
        await settle(tester);
        expect(find.text('作者甲 的作品'), findsOneWidget);
        expect(find.text('当前${type.label}'), findsNothing);
        expect(find.text('作者甲${type.label}作品'), findsOneWidget);
        final card = tester.widget<MediaCard>(find.byType(MediaCard).first);
        expect(card.item.package, package);
        expect(card.item.type, type);
        await tester.tap(find.text('加载更多'));
        await settle(tester);
        expect(find.text('作者甲${type.label}作品'), findsOneWidget);
        expect(find.text('后续${type.label}作品'), findsOneWidget);
        await tester.tap(find.text('作者甲${type.label}作品'));
        await settle(tester);
        expect(find.text('其他${type.label}'), findsNWidgets(2));
        await tester.pageBack();
        await settle(tester);
        await tester.pageBack();
        await settle(tester);
        await tester.tap(find.widgetWithText(TextButton, '作者乙'));
        await settle(tester);
        expect(find.text('作者乙${type.label}作品'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      const legacyPackage = 'author_fixture_legacy';
      await tester.runAsync(
        () => ExtensionManager.instance.installFromScript(
          fixture(legacyPackage, MediaType.novel, legacy: true),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          key: UniqueKey(),
          home: const DetailPage(
            item: MediaItem(
              package: legacyPackage,
              type: MediaType.novel,
              title: '当前小说',
              url: '/current',
            ),
          ),
        ),
      );
      await settle(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Shelley, Mary'));
      await settle(tester);
      expect(find.text('旧插件作品'), findsOneWidget);
      expect(
        tester.widget<MediaCard>(find.byType(MediaCard).first).item.package,
        legacyPackage,
      );
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
