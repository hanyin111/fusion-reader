import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/app_update.dart';

class UpdateDevice {
  final UpdatePlatform platform;
  final String? abi;
  final Directory? cache;
  const UpdateDevice(this.platform, {this.abi, this.cache});
}

class PreparedAppUpdate {
  final Directory job;
  final File package;
  const PreparedAppUpdate(this.job, this.package);
}

class AppUpdateInstaller {
  static const channel = MethodChannel('app.fusionreader/updater');

  Future<UpdateDevice> device() async {
    if (Platform.isAndroid) {
      final info = await channel.invokeMapMethod<String, dynamic>(
        'platformInfo',
      );
      final path = info?['cachePath'];
      if (path is! String || path.isEmpty) {
        throw const FormatException('无法获取安装包缓存位置。');
      }
      return UpdateDevice(
        UpdatePlatform.android,
        abi: info?['abi'] as String?,
        cache: Directory(path),
      );
    }
    if (Platform.isWindows) {
      return UpdateDevice(
        UpdatePlatform.windows,
        cache: Directory(
          p.join((await getTemporaryDirectory()).path, 'FusionReaderUpdates'),
        ),
      );
    }
    return UpdateDevice(
      Platform.isIOS ? UpdatePlatform.ios : UpdatePlatform.other,
    );
  }

  Future<PreparedAppUpdate> createJob(UpdateDevice device) async {
    final cache = device.cache;
    if (cache == null) throw const FormatException('当前平台请通过发布页更新。');
    await cache.create(recursive: true);
    // Remove only our own completed jobs. An interrupted helper retains its
    // rollback copy; normal downloads are deleted on cancellation/page close.
    await for (final entity in cache.list(followLinks: false)) {
      if (entity is! Directory || !p.basename(entity.path).startsWith('job-')) {
        continue;
      }
      if (device.platform == UpdatePlatform.android &&
          DateTime.now().difference((await entity.stat()).modified).inDays >=
              1) {
        await discard(
          PreparedAppUpdate(entity, File(p.join(entity.path, 'package.apk'))),
          device,
        );
        continue;
      }
      final result = File(p.join(entity.path, 'result.json'));
      if (!await result.exists()) continue;
      try {
        final data = jsonDecode(await result.readAsString());
        if (data is Map &&
            data['status'] == 'complete' &&
            DateTime.now()
                    .difference((await result.stat()).modified)
                    .inMinutes >=
                5) {
          await discard(
            PreparedAppUpdate(entity, File(p.join(entity.path, 'package.zip'))),
            device,
          );
        }
      } catch (_) {
        /* A failed cleanup must not block a new update. */
      }
    }
    final job = await cache.createTemp('job-');
    return PreparedAppUpdate(
      job,
      File(
        p.join(
          job.path,
          device.platform == UpdatePlatform.android
              ? 'package.apk'
              : 'package.zip',
        ),
      ),
    );
  }

  Future<void> prepare(PreparedAppUpdate update, UpdateDevice device) async {
    if (device.platform == UpdatePlatform.windows) {
      final source = update.package.path;
      final target = p.join(update.job.path, 'payload');
      await Isolate.run(() => extractWindowsUpdate(source, target));
    }
  }

  Future<void> discard(PreparedAppUpdate update, UpdateDevice device) async {
    final cache = device.cache;
    if (cache == null ||
        p.dirname(p.normalize(p.absolute(update.job.path))) !=
            p.normalize(p.absolute(cache.path)) ||
        !p.basename(update.job.path).startsWith('job-') ||
        await FileSystemEntity.type(update.job.path, followLinks: false) !=
            FileSystemEntityType.directory) {
      return;
    }
    if (await update.job.exists()) await update.job.delete(recursive: true);
  }

  Future<void> install(PreparedAppUpdate update, UpdateDevice device) async {
    if (device.platform == UpdatePlatform.android) {
      await channel.invokeMethod<void>('installApk', {
        'path': update.package.path,
      });
      return;
    }
    if (device.platform != UpdatePlatform.windows) {
      throw const FormatException('请通过发布页更新当前平台。');
    }
    final executable = File(Platform.resolvedExecutable);
    if (p.basename(executable.path).toLowerCase() != 'fusion_reader.exe') {
      throw const FormatException('请使用正式 Windows 程序进行更新。');
    }
    final directory = executable.parent;
    // Check write access before closing the app; protected installations get
    // a useful error and keep the running version intact.
    final probe = File(
      p.join(
        directory.path,
        '.fusion-update-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    try {
      await probe.writeAsString('');
      await probe.delete();
    } on FileSystemException {
      throw const FormatException('程序文件夹不可写。请把聚阅放到可写文件夹，或从发布页下载更新。');
    }
    final script = File(p.join(update.job.path, 'update.ps1'));
    // A BOM is required for Chinese strings under Windows PowerShell 5.1.
    await script.writeAsString(
      '\uFEFF${await rootBundle.loadString('assets/update_windows.ps1')}',
    );
    final config = File(p.join(update.job.path, 'config.json'));
    await config.writeAsString(
      jsonEncode({'processId': pid, 'installDirectory': directory.path}),
    );
    await Process.start(
      '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        script.path,
        '-ConfigPath',
        config.path,
      ],
      mode: ProcessStartMode.detached,
    );
    await Hive.close();
    exit(0);
  }

  Future<void> openRelease(AppUpdateRelease release) async {
    if (Platform.isWindows) {
      final result = await Process.run(
        '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\rundll32.exe',
        ['url.dll,FileProtocolHandler', release.page.toString()],
      );
      if (result.exitCode != 0) throw const FormatException('无法打开发布页。');
      return;
    }
    await InAppBrowser.openWithSystemBrowser(
      url: WebUri(release.page.toString()),
    );
  }
}

/// Decode only a flat Windows bundle, rejecting traversal, links and Windows
/// filename aliases before writing anything. Installation uses these files.
Future<void> extractWindowsUpdate(String zipPath, String outputPath) async {
  final input = InputFileStream(zipPath);
  try {
    final archive = ZipDecoder().decodeStream(input);
    if (archive.length > 10000) throw const FormatException('更新包文件过多。');
    var total = 0;
    final names = <String>{};
    for (final file in archive) {
      final name = file.name.replaceAll('\\', '/');
      final parts = name.replaceFirst(RegExp(r'/$'), '').split('/');
      if (file.isSymbolicLink ||
          (file.mode & 0xf000) == 0xa000 ||
          parts.any(
            (part) =>
                part.isEmpty ||
                part == '.' ||
                part == '..' ||
                RegExp(r'[<>:"|?*\x00-\x1f]').hasMatch(part) ||
                part.endsWith('.') ||
                part.endsWith(' ') ||
                RegExp(
                  r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
                  caseSensitive: false,
                ).hasMatch(part),
          ) ||
          !names.add(name.toLowerCase())) {
        throw const FormatException('更新包包含无效文件路径。');
      }
      total += file.size;
      if (file.size < 0 || total > 1024 * 1024 * 1024) {
        throw const FormatException('更新包解压后过大。');
      }
    }
    if (!names.containsAll([
      'fusion_reader.exe',
      'flutter_windows.dll',
      'data/app.so',
    ])) {
      throw const FormatException('Windows 更新包不完整。');
    }
    for (final file in archive) {
      if (!file.isFile) continue;
      final destination = File(
        p.join(outputPath, file.name.replaceAll('\\', '/')),
      );
      await destination.parent.create(recursive: true);
      final output = OutputFileStream(destination.path);
      try {
        file.writeContent(output);
      } finally {
        await output.close();
      }
    }
  } finally {
    await input.close();
  }
}
