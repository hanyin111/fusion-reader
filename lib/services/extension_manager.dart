import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:package_info_plus/package_info_plus.dart';

import '../models/models.dart';
import 'extension_runtime.dart';
import 'extension_repository.dart';
import 'network.dart';
import 'storage.dart';

/// Owns installed plugins. Source scripts are distributed independently.
class ExtensionManager extends ChangeNotifier {
  ExtensionManager._();
  static final ExtensionManager instance = ExtensionManager._();

  static const legacyPackages = [
    'mangadex',
    'weebcentral',
    'picacg',
    'jmcomic',
    'gutenberg',
    'royalroad',
    'esjzone',
    'linovelib',
    'yhdm',
    'archiveanime',
  ];

  final Map<String, ExtensionService> _services = {};
  final Map<String, String> _loadErrors = {};
  late String _prelude;
  bool _initialized = false;
  ExtensionCatalog? catalog;
  bool checkingRepository = false;
  String? repositoryError;
  String appVersion = '1.4.0';
  final Set<String> _installing = {};
  final Set<String> _downloading = {};
  bool isInstalling(String package) =>
      _installing.contains(package) || _downloading.contains(package);
  String get repositoryUrl =>
      Storage.setting(
            'extension_repository_url',
            defaultValue: defaultExtensionRepository,
          )
          as String;
  RepositoryExtension? repositoryEntry(String package) {
    for (final entry in catalog?.extensions ?? <RepositoryExtension>[]) {
      if (entry.package == package) return entry;
    }
    return null;
  }

  bool hasUpdate(String package) {
    final script = _services[package]?.script;
    final entry = repositoryEntry(package);
    return script != null &&
        entry != null &&
        entry.supports(appVersion) &&
        entry.hasUpdate(script);
  }

  bool get initialized => _initialized;
  Map<String, String> get loadErrors => Map.unmodifiable(_loadErrors);

  /// Every known extension (enabled or not), sorted by type then name.
  List<ExtensionService> get all {
    final list = _services.values.toList()
      ..sort((a, b) {
        final t = a.meta.type.index.compareTo(b.meta.type.index);
        return t != 0 ? t : a.meta.name.compareTo(b.meta.name);
      });
    return list;
  }

  List<ExtensionService> get enabled =>
      all.where((s) => !Storage.isExtensionDisabled(s.meta.package)).toList();

  List<ExtensionService> byType(MediaType type) =>
      enabled.where((s) => s.meta.type == type).toList();

  ExtensionService? byPackage(String package) => _services[package];

  Future<void> init() async {
    if (_initialized) return;
    _prelude = await rootBundle.loadString('assets/js/runtime.js');

    try {
      appVersion = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}
    final cached = Storage.setting('extension_repository_cache');
    if (cached is Map && cached['url'] == repositoryUrl) {
      try {
        catalog = ExtensionCatalog.parse(
          cached['index'],
          repositoryUri(repositoryUrl),
        );
      } catch (_) {}
    }
    // Never wait for a remote repository during startup or offline reading.
    for (final entry in Storage.installedScripts().entries) {
      await _loadScript(entry.value, packageHint: entry.key);
    }
    _initialized = true;
    notifyListeners();
  }

  Future<ExtensionService?> _loadScript(
    String script, {
    String? packageHint,
  }) async {
    final meta = ExtensionMeta.parse(script);
    if (meta == null) {
      _loadErrors[packageHint ?? '?'] = '缺少 ==MiruExtension== 头部，无法解析';
      return null;
    }
    _services[meta.package]?.dispose();
    Network.declaredModes[meta.package] = NetMode.fromString(meta.network);
    final service = ExtensionService(
      meta: meta,
      script: script,
      prelude: _prelude,
    );
    if (!Storage.isExtensionDisabled(meta.package)) {
      try {
        await service.init();
        _loadErrors.remove(meta.package);
      } catch (e) {
        _loadErrors[meta.package] = e.toString();
      }
    }
    _services[meta.package] = service;
    notifyListeners();
    return service;
  }

  /// Install an extension from raw script text (pasted or downloaded).
  Future<ExtensionMeta> installFromScript(String script) async {
    final meta = ExtensionMeta.parse(script);
    if (meta != null && isInstalling(meta.package)) {
      throw Exception('该插件正在安装或更新，请稍后再试。');
    }
    return _installScript(script);
  }

  Future<ExtensionMeta> _installScript(String script) async {
    final meta = ExtensionMeta.parse(script);
    if (meta == null) {
      throw Exception('无效扩展：缺少 ==MiruExtension== 头部');
    }
    if (_installing.contains(meta.package)) {
      throw Exception('该插件正在安装或更新，请稍后再试。');
    }
    _installing.add(meta.package);
    notifyListeners();
    final previousMode = Network.declaredModes[meta.package];
    final candidate = ExtensionService(
      meta: meta,
      script: script,
      prelude: _prelude,
    );
    try {
      Network.declaredModes[meta.package] = NetMode.fromString(meta.network);
      if (!Storage.isExtensionDisabled(meta.package)) await candidate.init();
      await Storage.installScript(meta.package, script);
      _services[meta.package]?.dispose();
      _services[meta.package] = candidate;
      _loadErrors.remove(meta.package);
      return meta;
    } catch (_) {
      candidate.dispose();
      if (previousMode == null) {
        Network.declaredModes.remove(meta.package);
      } else {
        Network.declaredModes[meta.package] = previousMode;
      }
      rethrow;
    } finally {
      _installing.remove(meta.package);
      notifyListeners();
    }
  }

  /// Install an extension by downloading a .js file from a URL
  /// (compatible with Miru extension repository raw links).
  Future<ExtensionMeta> installFromUrl(String url) async {
    return installFromScript(await ExtensionRepository().downloadUrl(url));
  }

  Future<void> refreshRepository() async {
    if (checkingRepository) return;
    checkingRepository = true;
    repositoryError = null;
    notifyListeners();
    try {
      final next = await ExtensionRepository(url: repositoryUrl).fetch();
      await Storage.setSetting('extension_repository_cache', {
        'url': repositoryUrl,
        'index': next.json,
      });
      catalog = next;
    } catch (error) {
      repositoryError = error is FormatException
          ? error.message
          : '无法连接插件仓库，请检查网络或稍后重试。';
    } finally {
      checkingRepository = false;
      notifyListeners();
    }
  }

  Future<void> setRepository(String url) async {
    final normalized = repositoryUri(url).toString();
    // Validate the new repository before replacing a working setting/cache.
    final next = await ExtensionRepository(url: normalized).fetch();
    await Storage.setSetting('extension_repository_url', normalized);
    await Storage.setSetting('extension_repository_cache', {
      'url': normalized,
      'index': next.json,
    });
    catalog = next;
    repositoryError = null;
    notifyListeners();
  }

  Future<ExtensionMeta> installFromRepository(RepositoryExtension entry) async {
    if (isInstalling(entry.package)) throw Exception('该插件正在安装或更新，请稍后再试。');
    if (!entry.supports(appVersion)) {
      throw Exception('该插件需要应用 ${entry.minAppVersion} 或更新版本。');
    }
    final installed = _services[entry.package];
    if (installed != null && !entry.hasUpdate(installed.script)) {
      throw Exception('已安装相同或更新版本的插件。');
    }
    _downloading.add(entry.package);
    notifyListeners();
    try {
      final script = await ExtensionRepository(
        url: repositoryUrl,
      ).download(entry);
      return await _installScript(script);
    } finally {
      _downloading.remove(entry.package);
      notifyListeners();
    }
  }

  Future<Map<String, String>> updateInstalled({
    bool restoreLegacy = false,
  }) async {
    await refreshRepository();
    if (repositoryError != null) throw Exception(repositoryError);
    final failures = <String, String>{};
    for (final entry in catalog?.extensions ?? <RepositoryExtension>[]) {
      final restore =
          restoreLegacy &&
          legacyPackages.contains(entry.package) &&
          byPackage(entry.package) == null;
      if (!restore && !hasUpdate(entry.package)) continue;
      try {
        await installFromRepository(entry);
      } catch (_) {
        failures[entry.name] = '安装或更新失败，原插件保留';
      }
    }
    return failures;
  }

  Future<void> uninstall(String package) async {
    if (isInstalling(package)) throw Exception('该插件正在更新，请稍后再试。');
    await Storage.uninstallScript(package);
    _services[package]?.dispose();
    _services.remove(package);
    _loadErrors.remove(package);
    notifyListeners();
  }

  Future<void> setDisabled(String package, bool disabled) async {
    if (isInstalling(package)) return;
    await Storage.setExtensionDisabled(package, disabled);
    final service = _services[package];
    if (service != null) {
      if (disabled) {
        service.dispose();
      } else {
        try {
          await service.init();
          _loadErrors.remove(package);
        } catch (e) {
          _loadErrors[package] = e.toString();
        }
      }
    }
    notifyListeners();
  }

  /// Recreate a source's runtime, e.g. after its network routing changed.
  Future<void> reload(String package) async {
    final service = _services[package];
    if (service == null) return;
    service.dispose();
    if (Storage.isExtensionDisabled(package)) {
      notifyListeners();
      return;
    }
    try {
      await service.init();
      _loadErrors.remove(package);
    } catch (e) {
      _loadErrors[package] = e.toString();
    }
    notifyListeners();
  }

  /// Ensure a service is initialized before use (lazy re-init after enable).
  Future<ExtensionService> ensureLoaded(String package) async {
    final service = _services[package];
    if (service == null) throw Exception('扩展 $package 未安装');
    if (!service.loaded) await service.init();
    return service;
  }
}
