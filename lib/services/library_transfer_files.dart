import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import 'library_backup.dart';

/// The mobile picker saves supplied bytes itself; desktop pickers only return
/// a path. In particular macOS rejects the `bytes` argument entirely.
class LibraryTransferFiles {
  final FilePicker picker;
  LibraryTransferFiles({FilePicker? picker})
    : picker = picker ?? FilePicker.platform;

  Future<String?> save(LibraryBackup backup) async {
    final bytes = backup.encodeBytes();
    final date = backup.exportedAt
        .toLocal()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final mobile = Platform.isAndroid || Platform.isIOS;
    final path = await picker.saveFile(
      dialogTitle: '导出书架与历史',
      fileName: 'FusionReader-$date.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
      bytes: mobile ? bytes : null,
      lockParentWindow: true,
    );
    if (path == null) return null;
    if (!mobile) await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  Future<PickedLibraryBackup?> pick() async {
    final result = await picker.pickFiles(
      dialogTitle: '导入书架与历史',
      type: FileType.custom,
      allowedExtensions: ['json'],
      withReadStream: true,
      lockParentWindow: true,
    );
    if (result == null) return null;
    final file = result.files.single;
    if (file.size > LibraryBackup.maxBytes) {
      throw const FormatException('备份文件超过 20 MB。');
    }
    final stream =
        file.readStream ??
        (file.path == null ? null : File(file.path!).openRead());
    Uint8List bytes;
    if (stream != null) {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in stream) {
        if (builder.length + chunk.length > LibraryBackup.maxBytes) {
          throw const FormatException('备份文件超过 20 MB。');
        }
        builder.add(chunk);
      }
      bytes = builder.takeBytes();
    } else if (file.bytes != null) {
      bytes = file.bytes!;
    } else {
      throw const FileSystemException('无法读取所选文件，请先下载到本机后重试。');
    }
    // Parse off the UI thread so a large history file does not freeze scrolling.
    final backup = await compute(LibraryBackup.decode, bytes);
    return PickedLibraryBackup(name: file.name, backup: backup);
  }
}

class PickedLibraryBackup {
  final String name;
  final LibraryBackup backup;
  const PickedLibraryBackup({required this.name, required this.backup});
}
