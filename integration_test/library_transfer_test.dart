import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/pages/library_transfer_page.dart';
import 'package:fusion_reader/pages/settings_page.dart';
import 'package:fusion_reader/services/library_backup.dart';
import 'package:fusion_reader/services/library_transfer_files.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../test/history_test.dart' show novel, comic, progress;

class _TestPaths extends PathProviderPlatform {
  final String root;
  _TestPaths(this.root);
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

/// Only the OS dialog is substituted. Streaming, UTF-8 decoding, background
/// validation, Hive writes, file saving and the confirmation UI are real.
class _Picker extends FilePicker {
  Uint8List? incoming;
  String? destination;
  Uint8List? suppliedSaveBytes;
  bool cancelPick = false;
  bool cancelSave = false;
  int? reportedSize;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    if (cancelPick) return null;
    final bytes = incoming!;
    return FilePickerResult([
      PlatformFile(
        name: '另一台设备.json',
        size: reportedSize ?? bytes.length,
        readStream: Stream.fromIterable([
          bytes.sublist(0, 3),
          bytes.sublist(3),
        ]),
      ),
    ]);
  }

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    suppliedSaveBytes = bytes;
    if (cancelSave) return null;
    // Simulate the mobile native picker writing bytes itself.
    if (bytes != null) {
      await File(destination!).writeAsBytes(bytes, flush: true);
    }
    return destination;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform originalPaths;
  late FilePicker originalPicker;
  late _Picker picker;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('fusion_transfer_native_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(root.path);
    originalPicker = FilePicker.platform;
    await Storage.init();
  });
  setUp(() async {
    await Storage.favoritesBox.clear();
    await Storage.clearHistory();
    await Storage.localBox.clear();
    picker = _Picker();
    picker.destination =
        '${root.path}/export-${DateTime.now().microsecondsSinceEpoch}.json';
    FilePicker.platform = picker;
  });
  tearDownAll(() async {
    await Hive.close();
    FilePicker.platform = originalPicker;
    PathProviderPlatform.instance = originalPaths;
    await root.delete(recursive: true);
  });

  Future<void> showTransfer(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryTransferPage(files: LibraryTransferFiles(picker: picker)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapAndWait(WidgetTester tester, String label) async {
    final button = find.text(label);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    // Give native file I/O and the validation isolate time outside frame pumps.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'settings opens transfer; cancel leaves data untouched, confirmed import and export round-trip',
    (tester) async {
      await Storage.toggleFavorite(novel);
      await Storage.saveHistory(progress(novel, 123));
      await Storage.recordVisit(comic);
      picker.incoming = LibraryBackup.capture().encodeBytes();
      await Storage.favoritesBox.clear();
      await Storage.clearHistory();

      await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('导入与导出'));
      await tester.tap(find.text('导入与导出'));
      await tester.pumpAndSettle();
      expect(find.text('0 项书架收藏 · 0 条浏览历史'), findsOneWidget);
      await tapAndWait(tester, '导入 JSON');
      expect(find.text('确认导入'), findsOneWidget);
      expect(find.text('书架收藏：1 项'), findsOneWidget);
      expect(find.text('浏览历史：2 条（含阅读进度）'), findsOneWidget);
      expect(find.textContaining('需要安装对应插件'), findsOneWidget);
      await tapAndWait(tester, '取消');
      expect(Storage.favorites(), isEmpty);
      expect(Storage.history(), isEmpty);
      await tapAndWait(tester, '导入 JSON');
      await tapAndWait(tester, '合并导入');
      expect(find.text('1 项书架收藏 · 2 条浏览历史'), findsOneWidget);
      expect(find.textContaining('导入完成'), findsOneWidget);
      expect(Storage.historyOf(novel.key)!.position, 37);
      expect(Storage.historyOf(comic.key), isNull);

      await tapAndWait(tester, '导出 JSON');
      expect(find.textContaining('已导出 1 项收藏、2 条历史'), findsOneWidget);
      final exported = LibraryBackup.decode(
        await File(picker.destination!).readAsBytes(),
      );
      expect(exported.favorites.single.title, novel.title);
      expect(exported.history, hasLength(2));
      if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
        expect(picker.suppliedSaveBytes, isNull);
      } else {
        expect(picker.suppliedSaveBytes, isNotNull);
      }
    },
  );

  testWidgets(
    'malformed input and picker cancellation preserve existing data and keep buttons usable',
    (tester) async {
      await Storage.toggleFavorite(novel);
      await Storage.saveHistory(progress(novel, 123));
      picker.incoming = Uint8List.fromList(utf8.encode('{invalid json}'));
      await showTransfer(tester);
      await tapAndWait(tester, '导入 JSON');
      expect(find.textContaining('不是有效的 UTF-8 JSON'), findsOneWidget);
      expect(find.text('确认导入'), findsNothing);
      expect(Storage.historyOf(novel.key)!.position, 37);
      expect(Storage.favorites().single.key, novel.key);
      picker.cancelPick = true;
      await tapAndWait(tester, '导入 JSON');
      expect(find.textContaining('不是有效的 UTF-8 JSON'), findsNothing);
      picker.cancelSave = true;
      await tapAndWait(tester, '导出 JSON');
      expect(await File(picker.destination!).exists(), isFalse);
      expect(Storage.historyOf(novel.key)!.timestamp, 123);
      final exportButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '导出 JSON'),
      );
      expect(exportButton.onPressed, isNotNull);
    },
  );

  testWidgets(
    'oversized streams and failed saves report errors without changing records',
    (tester) async {
      await Storage.toggleFavorite(novel);
      await Storage.saveHistory(progress(novel, 123));
      picker.incoming = Uint8List(LibraryBackup.maxBytes + 1);
      picker.reportedSize = 1;
      await showTransfer(tester);
      await tapAndWait(tester, '导入 JSON');
      expect(find.text('备份文件超过 20 MB。'), findsOneWidget);
      expect(find.text('确认导入'), findsNothing);
      expect(Storage.favorites().single.key, novel.key);
      expect(Storage.historyOf(novel.key)!.position, 37);
      picker.destination = '${root.path}/nonexistent-folder/export.json';
      await tapAndWait(tester, '导出 JSON');
      expect(find.textContaining('操作失败'), findsOneWidget);
      expect(find.textContaining('已导出'), findsNothing);
      expect(Storage.historyOf(novel.key)!.timestamp, 123);
    },
  );
}
