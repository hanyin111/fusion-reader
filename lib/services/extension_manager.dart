import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../models/models.dart';
import 'extension_runtime.dart';
import 'network.dart';
import 'storage.dart';

/// Loads bundled + user-installed extensions and owns their runtimes.
class ExtensionManager extends ChangeNotifier {
  ExtensionManager._();
  static final ExtensionManager instance = ExtensionManager._();

  static const bundledPackages = [
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

    final scripts = <String, String>{};
    for (final pkg in bundledPackages) {
      try {
        scripts[pkg] = await rootBundle.loadString('assets/extensions/$pkg.js');
      } catch (e) {
        _loadErrors[pkg] = 'bundled asset missing: $e';
      }
    }
    // User-installed scripts override bundled ones with the same package name.
    scripts.addAll(Storage.installedScripts());

    for (final entry in scripts.entries) {
      await _loadScript(entry.value, packageHint: entry.key);
    }
    _initialized = true;
    notifyListeners();
  }

  Future<ExtensionService?> _loadScript(String script, {String? packageHint}) async {
    final meta = ExtensionMeta.parse(script);
    if (meta == null) {
      _loadErrors[packageHint ?? '?'] = '缺少 ==MiruExtension== 头部，无法解析';
      return null;
    }
    _services[meta.package]?.dispose();
    Network.declaredModes[meta.package] = NetMode.fromString(meta.network);
    final service = ExtensionService(meta: meta, script: script, prelude: _prelude);
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
    if (meta == null) {
      throw Exception('无效扩展：缺少 ==MiruExtension== 头部');
    }
    await Storage.installScript(meta.package, script);
    await _loadScript(script);
    return meta;
  }

  /// Install an extension by downloading a .js file from a URL
  /// (compatible with Miru extension repository raw links).
  Future<ExtensionMeta> installFromUrl(String url) async {
    final res = await Network.proxied.get<String>(url);
    return installFromScript(res.data ?? '');
  }

  Future<void> uninstall(String package) async {
    await Storage.uninstallScript(package);
    _services[package]?.dispose();
    _services.remove(package);
    _loadErrors.remove(package);
    notifyListeners();
  }

  Future<void> setDisabled(String package, bool disabled) async {
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
