import 'package:hive_flutter/hive_flutter.dart';

import '../models/models.dart';
import 'offline_cache.dart';

/// Thin wrapper around Hive boxes. Pure Dart storage, works on every platform.
class Storage {
  static late Box _favorites;
  static late Box _history;
  static late Box _settings;
  static late Box _extensions; // user-installed scripts: package -> source code
  static late Box _extSettings; // extension key-value settings
  static late Box _disabled; // disabled extension packages
  static late Box _local; // locally imported books/comics/videos

  static Future<void> init() async {
    await Hive.initFlutter('FusionReader');
    _favorites = await Hive.openBox('favorites');
    _history = await Hive.openBox('history');
    _settings = await Hive.openBox('settings');
    _extensions = await Hive.openBox('extension_scripts');
    _extSettings = await Hive.openBox('extension_settings');
    _disabled = await Hive.openBox('extensions_disabled');
    _local = await Hive.openBox('local_library');
    await OfflineCache.init(await Hive.openBox('offline_manifests'));
  }

  // ---- local library ----
  static Box get localBox => _local;

  static List<MediaItem> localItems() =>
      _local.values.whereType<Map>().map(MediaItem.fromJson).toList();

  static Future<void> addLocalItem(MediaItem item) =>
      _local.put(item.url, item.toJson());

  static Future<void> removeLocalItem(String path) => _local.delete(path);

  // ---- favorites (the unified library) ----
  static Box get favoritesBox => _favorites;

  static List<MediaItem> favorites() => _favorites.values
      .whereType<Map>()
      .map(MediaItem.fromJson)
      .toList()
      .reversed
      .toList();

  static bool isFavorite(String key) => _favorites.containsKey(key);

  static Future<void> toggleFavorite(MediaItem item) async {
    if (_favorites.containsKey(item.key)) {
      await _favorites.delete(item.key);
    } else {
      await _favorites.put(item.key, item.toJson());
    }
  }

  // ---- history ----
  static Box get historyBox => _history;

  static HistoryRecord? historyOf(String key) {
    final v = _history.get(key);
    if (v is Map) return HistoryRecord.fromJson(v);
    return null;
  }

  static Future<void> saveHistory(HistoryRecord record) =>
      _history.put(record.key, record.toJson());

  // ---- app settings ----
  static String get proxy => _settings.get('proxy', defaultValue: '') as String;
  static Future<void> setProxy(String v) => _settings.put('proxy', v);

  static dynamic setting(String key, {dynamic defaultValue}) =>
      _settings.get(key, defaultValue: defaultValue);
  static Future<void> setSetting(String key, dynamic value) =>
      _settings.put(key, value);

  // ---- user-installed extensions ----
  static Map<String, String> installedScripts() => Map.fromEntries(_extensions
      .toMap()
      .entries
      .map((e) => MapEntry(e.key.toString(), e.value.toString())));

  static Future<void> installScript(String package, String script) =>
      _extensions.put(package, script);

  static Future<void> uninstallScript(String package) =>
      _extensions.delete(package);

  static bool isInstalledByUser(String package) =>
      _extensions.containsKey(package);

  // ---- extension enable/disable ----
  static bool isExtensionDisabled(String package) =>
      _disabled.get(package, defaultValue: false) as bool;

  static Future<void> setExtensionDisabled(String package, bool disabled) =>
      _disabled.put(package, disabled);

  // ---- per-extension settings (registerSetting / getSetting bridge) ----
  static dynamic extSetting(String package, String key) =>
      _extSettings.get('$package|$key');

  static Future<void> setExtSetting(String package, String key, dynamic value) =>
      _extSettings.put('$package|$key', value);

  // ---- setting declarations, so the UI can render an editor ----
  static List<Map> extSettingSchemas(String package) {
    final raw = _extSettings.get('$package|__schemas');
    if (raw is List) return raw.whereType<Map>().toList();
    return const [];
  }

  static Future<void> putExtSettingSchema(String package, Map schema) async {
    final list = extSettingSchemas(package).toList();
    final i = list.indexWhere((e) => e['key'] == schema['key']);
    if (i >= 0) {
      list[i] = schema;
    } else {
      list.add(schema);
    }
    await _extSettings.put('$package|__schemas', list);
  }

  // ---- per-extension network routing ----
  // Null means "not overridden by the user"; the extension's own @network
  // declaration (applied at load time) or the global default then applies.
  static String? extNetMode(String package) =>
      _extSettings.get('$package|__netmode') as String?;

  static Future<void> setExtNetMode(String package, String mode) =>
      _extSettings.put('$package|__netmode', mode);
}
