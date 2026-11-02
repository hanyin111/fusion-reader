import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/pages/library_page.dart';
import 'package:fusion_reader/services/content_filter.dart';
import 'package:fusion_reader/services/extension_repository.dart';
import 'package:fusion_reader/services/library_backup.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'extension_repository_test.dart' show entryFor, script;

class _Paths extends PathProviderPlatform {
  final String root;
  _Paths(this.root);
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

const book = MediaItem(
  package: 'fixture',
  type: MediaType.novel,
  title: '测试作品',
  url: '/book',
);
String source(bool nsfw) =>
    script.replaceFirst('@type fikushon', '@type fikushon\n// @nsfw $nsfw');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform paths;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('fusion_content_filter_');
    paths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    await Storage.init();
  });
  setUp(() async {
    await Storage.favoritesBox.clear();
    await Storage.clearHistory();
    await Storage.settingsBox.clear();
    await Storage.extensionsBox.clear();
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = paths;
    await root.delete(recursive: true);
  });

  test(
    'legacy books inherit current source label; visibility never deletes data',
    () async {
      await Storage.installScript('fixture', source(true));
      await Storage.toggleFavorite(book);
      expect(ContentFilter.showNsfw, isFalse);
      expect(ContentFilter.allowsSource(true), isFalse);
      expect(ContentFilter.allowsItem(book), isFalse);
      await ContentFilter.setShowNsfw(true);
      expect(ContentFilter.allowsItem(book), isTrue);
      await ContentFilter.setShowNsfw(false);
      expect(Storage.favorites(), hasLength(1));
      // A changed source declaration is used without restarting the app.
      await Storage.installScript('fixture', source(false));
      expect(ContentFilter.allowsItem(book), isTrue);
    },
  );

  test(
    'per-book override survives visits, progress saves and returning to source default',
    () async {
      await Storage.installScript('fixture', source(true));
      await Storage.toggleFavorite(book);
      await Storage.setContentRating(book, ContentRating.sfw);
      await Storage.recordVisit(book);
      expect(ContentFilter.allowsItem(Storage.history().single.item!), isTrue);
      await Storage.saveHistory(
        HistoryRecord(
          key: book.key,
          episodeUrl: '/c2',
          episodeName: '第二章',
          groupIndex: 0,
          episodeIndex: 1,
          timestamp: 100,
        ),
        item: book,
      );
      expect(Storage.history().single.item!.contentRating, ContentRating.sfw);
      await Storage.setContentRating(book, ContentRating.source);
      await Storage.recordVisit(book); // stale detail page has no override
      expect(ContentFilter.allowsItem(book), isFalse);
      expect(Storage.historyOf(book.key)!.episodeIndex, 1);
      await Storage.setContentRating(book, ContentRating.nsfw);
      await Storage.installScript('fixture', source(false));
      expect(ContentFilter.allowsItem(book), isFalse);
    },
  );

  test(
    'export includes hidden books and preserves labels after source removal/import',
    () async {
      await Storage.installScript('fixture', source(true));
      await Storage.favoritesBox.put(
        book.key,
        book.toJson(),
      ); // old installation
      await Storage.recordVisit(book);
      final backup = LibraryBackup.decode(
        LibraryBackup.capture().encodeBytes(),
      );
      expect(backup.favorites, hasLength(1));
      expect(backup.favorites.single.sourceNsfw, isTrue);
      await Storage.uninstallScript('fixture');
      expect(ContentFilter.allowsItem(Storage.favorites().single), isFalse);
      await Storage.favoritesBox.clear();
      await Storage.clearHistory();
      await backup.merge();
      expect(ContentFilter.allowsItem(Storage.favorites().single), isFalse);
      await Storage.setContentRating(book, ContentRating.sfw);
      final marked = LibraryBackup.decode(
        LibraryBackup.capture().encodeBytes(),
      );
      await Storage.setContentRating(book, ContentRating.source);
      await marked.merge(); // an older imported label cannot undo the reset
      expect(ContentFilter.allowsItem(Storage.favorites().single), isFalse);
    },
  );

  test(
    'repository reads optional rating and checks script agrees before install',
    () {
      final text = source(true);
      final json = {...entryFor(text), 'nsfw': true};
      final url = Uri.parse('https://example.test/index.json');
      final entry = RepositoryExtension.parse(json, url);
      expect(entry.nsfw, isTrue);
      expect(entry.verify(utf8.encode(text)), text);
      expect(
        () => RepositoryExtension.parse({
          ...json,
          'nsfw': false,
        }, url).verify(utf8.encode(text)),
        throwsFormatException,
      );
      expect(
        () => RepositoryExtension.parse({...json, 'nsfw': 'false'}, url),
        throwsFormatException,
      );
      expect(RepositoryExtension.parse(entryFor(script), url).nsfw, isFalse);
    },
  );

  testWidgets(
    'shelf mode and individual rating update immediately without deleting favorites',
    (tester) async {
      await tester.runAsync(() async {
        await Storage.installScript('fixture', source(true));
        await Storage.toggleFavorite(book);
      });
      await tester.pumpWidget(const MaterialApp(home: LibraryPage()));
      expect(find.text(book.title), findsNothing);
      await tester.runAsync(() => ContentFilter.setShowNsfw(true));
      await tester.pumpAndSettle();
      expect(find.text(book.title), findsOneWidget);
      await tester.tap(find.byTooltip('书架管理与内容分级'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('单独设为 SFW'));
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() => ContentFilter.setShowNsfw(false));
      await tester.pumpAndSettle();
      expect(find.text(book.title), findsOneWidget);
      expect(Storage.favorites(), hasLength(1));
      await tester.pumpWidget(const SizedBox());
      var closed = false;
      Hive.close().then((_) => closed = true);
      for (var i = 0; i < 100 && !closed; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(closed, isTrue);
    },
  );
}
