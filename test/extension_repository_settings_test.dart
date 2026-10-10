import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/pages/extension_repository_page.dart';
import 'package:fusion_reader/services/extension_manager.dart';
import 'package:fusion_reader/services/extension_repository.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'extension_repository_test.dart' show MemoryAdapter, script, entryFor;

class TestPaths extends PathProviderPlatform {
  final String root;
  TestPaths(this.root);
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const selected = 'https://custom.example.test/index.json';
  final index = {
    'schemaVersion': 1,
    'name': 'User repository',
    'extensions': [entryFor(script)],
  };
  late Directory root;
  late PathProviderPlatform paths;
  late MemoryAdapter adapter;
  late Dio client;
  late ExtensionManager manager;
  final factories = <String>[];
  ExtensionManager makeManager() => ExtensionManager.forTesting(
    repositoryFactory: (url) {
      factories.add(url);
      return ExtensionRepository(url: url, client: client);
    },
  );

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('fusion_manual_repository_');
    paths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = TestPaths(root.path);
    await Storage.init();
  });
  setUp(() async {
    await Storage.settingsBox.clear();
    factories.clear();
    adapter = MemoryAdapter({selected: utf8.encode(jsonEncode(index))});
    client = Dio()..httpClientAdapter = adapter;
    manager = makeManager();
  });
  tearDown(() {
    manager.dispose();
    client.close();
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = paths;
    final temporary = Directory.systemTemp.absolute.path.toLowerCase();
    if (!root.absolute.path.toLowerCase().startsWith(
          '$temporary${Platform.pathSeparator}',
        ) ||
        !root.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('fusion_manual_repository_')) {
      throw StateError('Refusing to remove a path outside the test fixture');
    }
    await root.delete(recursive: true);
  });

  test(
    'fresh and upgraded automatic caches never select a repository or make requests',
    () async {
      await Storage.setSetting('extension_repository_cache', {
        'url': selected,
        'index': index,
      });
      await manager.init();
      await manager.refreshRepository();
      expect(manager.hasRepository, isFalse);
      expect(manager.repositoryUrl, isEmpty);
      expect(manager.catalog, isNull);
      expect(manager.checkingRepository, isFalse);
      expect(factories, isEmpty);
      expect(adapter.requests, isEmpty);
      await expectLater(manager.updateInstalled(), throwsFormatException);
    },
  );

  test(
    'manually selected repository persists and its cache opens offline on the next start',
    () async {
      await manager.setRepository('  $selected  ');
      expect(manager.repositoryUrl, selected);
      expect(manager.hasRepository, isTrue);
      expect(adapter.requests, [selected]);
      expect(factories, [selected]);
      final reopened = makeManager();
      try {
        await reopened.init();
        expect(reopened.repositoryUrl, selected);
        expect(reopened.catalog!.name, 'User repository');
        expect(reopened.catalog!.extensions.single.package, 'fixture');
        expect(adapter.requests, [selected]);
      } finally {
        reopened.dispose();
      }
    },
  );

  test(
    'an invalid or unreachable replacement keeps the previous link and catalog',
    () async {
      await manager.setRepository(selected);
      final previous = manager.catalog;
      await expectLater(manager.setRepository(''), throwsFormatException);
      await expectLater(
        manager.setRepository('http://example.test/index.json'),
        throwsFormatException,
      );
      await expectLater(
        manager.setRepository('https://missing.example.test/index.json'),
        throwsA(isA<DioException>()),
      );
      expect(manager.repositoryUrl, selected);
      expect(manager.catalog, same(previous));
      expect(Storage.setting('extension_repository_cache')['url'], selected);
      expect(manager.checkingRepository, isFalse);
    },
  );

  testWidgets(
    'empty repository page asks for a link and rejects empty input without any default',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: ExtensionRepositoryPage(manager: manager)),
      );
      await tester.pumpAndSettle();
      expect(find.text('先添加插件仓库'), findsOneWidget);
      expect(factories, isEmpty);
      await tester.tap(find.text('填写仓库链接'));
      await tester.pumpAndSettle();
      expect(find.text('使用默认仓库'), findsNothing);
      expect(
        tester.widget<TextFormField>(find.byType(TextFormField)).initialValue,
        isEmpty,
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('请填写插件仓库链接'), findsOneWidget);
      expect(factories, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );
}
