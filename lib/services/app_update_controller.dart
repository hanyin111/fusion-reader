import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/app_update.dart';
import 'app_update_api.dart';
import 'app_update_installer.dart';

enum AppUpdatePhase {
  checking,
  current,
  available,
  downloading,
  verifying,
  ready,
  installing,
  failed,
}

class AppUpdateController extends ChangeNotifier {
  final AppUpdateApi api;
  final AppUpdateInstaller installer;
  final Future<String> Function() versionLoader;
  AppUpdateController({
    AppUpdateApi? api,
    AppUpdateInstaller? installer,
    Future<String> Function()? versionLoader,
  }) : api = api ?? AppUpdateApi(),
       installer = installer ?? AppUpdateInstaller(),
       versionLoader =
           versionLoader ??
           (() async => (await PackageInfo.fromPlatform()).version);

  AppUpdatePhase phase = AppUpdatePhase.checking;
  String currentVersion = '', error = '', message = '';
  int received = 0, total = 0;
  UpdateDevice? device;
  AppUpdateRelease? release;
  PreparedAppUpdate? _prepared;
  CancelToken? _cancel;
  bool _disposed = false, _handedOff = false;
  bool get busy => const [
    AppUpdatePhase.checking,
    AppUpdatePhase.downloading,
    AppUpdatePhase.verifying,
    AppUpdatePhase.installing,
  ].contains(phase);
  bool get canInstall => const [
    UpdatePlatform.android,
    UpdatePlatform.windows,
  ].contains(device?.platform);
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> check() async {
    if (_disposed || _cancel != null || phase == AppUpdatePhase.installing) {
      return;
    }
    final cancel = _cancel = CancelToken();
    phase = AppUpdatePhase.checking;
    error = message = '';
    release = null;
    _notify();
    try {
      device ??= await installer.device();
      currentVersion = await versionLoader();
      final version = AppVersion.parse(currentVersion);
      if (version == null) throw const FormatException('无法识别当前应用版本。');
      cancel.throwIfCancellationRequested();
      release = await api.latest(
        device!.platform,
        abi: device!.abi,
        cancel: cancel,
      );
      cancel.throwIfCancellationRequested();
      if (_prepared != null && !_handedOff) {
        await installer.discard(_prepared!, device!);
      }
      _prepared = null;
      _handedOff = false;
      phase = release!.version.compareTo(version) > 0
          ? AppUpdatePhase.available
          : AppUpdatePhase.current;
    } catch (e) {
      phase = AppUpdatePhase.failed;
      error = _error(e);
    } finally {
      _cancel = null;
      _notify();
    }
  }

  Future<void> download() async {
    final asset = release?.asset;
    if (_disposed || busy || asset == null || !canInstall) return;
    final cancel = _cancel = CancelToken();
    PreparedAppUpdate? job;
    _handedOff = false;
    phase = AppUpdatePhase.downloading;
    error = message = '';
    received = 0;
    total = asset.size;
    _notify();
    try {
      job = await installer.createJob(device!);
      cancel.throwIfCancellationRequested();
      await api.download(
        asset,
        job.package,
        cancel: cancel,
        progress: (bytes, size) {
          received = bytes;
          total = size;
          phase = bytes == size
              ? AppUpdatePhase.verifying
              : AppUpdatePhase.downloading;
          _notify();
        },
      );
      phase = AppUpdatePhase.verifying;
      _notify();
      await installer.prepare(job, device!);
      cancel.throwIfCancellationRequested();
      _prepared = job;
      phase = AppUpdatePhase.ready;
    } catch (e) {
      if (job != null) {
        try {
          await installer.discard(job, device!);
        } catch (_) {
          /* Cleanup is best effort. */
        }
      }
      phase = AppUpdatePhase.available;
      error = e is DioException && CancelToken.isCancel(e) ? '' : _error(e);
    } finally {
      _cancel = null;
      _notify();
    }
  }

  void cancelDownload() => _cancel?.cancel('cancelled');

  Future<void> install() async {
    if (_disposed || phase != AppUpdatePhase.ready || _prepared == null) return;
    phase = AppUpdatePhase.installing;
    error = '';
    _handedOff = true;
    _notify();
    try {
      await installer.install(_prepared!, device!);
      // Android still asks the user to confirm in its own installer. Do not
      // claim the app has already updated, or remove the APK under that UI.
      message = '已打开系统安装界面，请确认安装。';
      phase = AppUpdatePhase.ready;
    } catch (e) {
      _handedOff = false;
      phase = AppUpdatePhase.ready;
      error = _error(e);
    }
    _notify();
  }

  Future<void> openRelease() async {
    if (release == null) return;
    try {
      await installer.openRelease(release!);
    } catch (_) {
      error = '无法打开发布页，请稍后重试。';
      _notify();
    }
  }

  static String _error(Object e) {
    if (e is FormatException) return e.message;
    if (e is PlatformException) return e.message ?? '无法启动系统安装，请重试。';
    if (e is DioException) return '连接失败，请检查网络或系统代理后重试。';
    return '更新操作失败，请检查网络、可用空间和文件夹权限后重试。';
  }

  @override
  void dispose() {
    _disposed = true;
    _cancel?.cancel();
    api.close();
    if (_prepared != null && !_handedOff && device != null) {
      unawaited(
        installer.discard(_prepared!, device!).catchError((Object _) {}),
      );
    }
    super.dispose();
  }
}
