import 'dart:convert';
import 'dart:typed_data';

import '../models/models.dart';
import 'storage.dart';

/// Versioned, portable metadata only. Device paths and source credentials are
/// deliberately kept out of this format.
class LibraryBackup {
  static const schemaVersion = 1;
  static const maxBytes = 20 * 1024 * 1024;
  static const maxRecords = 50000;

  final DateTime exportedAt;
  final List<MediaItem> favorites;
  final List<HistoryRecord> history;
  final int excludedLocalFavorites;
  final int excludedLocalHistory;

  LibraryBackup._({
    required this.exportedAt,
    required Iterable<MediaItem> favorites,
    required Iterable<HistoryRecord> history,
    this.excludedLocalFavorites = 0,
    this.excludedLocalHistory = 0,
  }) : favorites = List.unmodifiable(favorites),
       history = List.unmodifiable(history);

  factory LibraryBackup.capture() {
    final favorites = Storage.favorites();
    final history = Storage.history();
    return LibraryBackup._(
      exportedAt: DateTime.now().toUtc(),
      favorites: favorites.where((item) => item.package != 'local'),
      history: history.where((record) => _package(record.key) != 'local'),
      excludedLocalFavorites: favorites
          .where((item) => item.package == 'local')
          .length,
      excludedLocalHistory: history
          .where((record) => _package(record.key) == 'local')
          .length,
    );
  }

  Set<String> get packages => {
    ...favorites.map((item) => item.package),
    ...history.map((record) => _package(record.key)),
  };

  String encode() => const JsonEncoder.withIndent('  ').convert({
    'format': 'FusionReader.library',
    'schemaVersion': schemaVersion,
    'exportedAt': exportedAt.toUtc().toIso8601String(),
    'favorites': favorites.map((item) => item.toJson()).toList(),
    'history': history.map((record) => record.toJson()).toList(),
    'excludedLocalFavorites': excludedLocalFavorites,
    'excludedLocalHistory': excludedLocalHistory,
  });

  Uint8List encodeBytes() {
    if (favorites.length + history.length > maxRecords) {
      throw const FormatException('备份记录过多，最多支持 50000 条。');
    }
    final bytes = Uint8List.fromList(utf8.encode(encode()));
    _checkSize(bytes.length);
    return bytes;
  }

  /// The last accepted cloud snapshot is the common ancestor. A removal on
  /// either device wins over an unchanged copy on the other device.
  static LibraryBackup reconcile({
    required LibraryBackup local,
    required LibraryBackup remote,
    LibraryBackup? baseline,
  }) {
    final localFavorites = {for (final item in local.favorites) item.key: item};
    final remoteFavorites = {
      for (final item in remote.favorites) item.key: item,
    };
    final localHistory = {for (final item in local.history) item.key: item};
    final remoteHistory = {for (final item in remote.history) item.key: item};
    final removedFavorites = {
      for (final item in baseline?.favorites ?? <MediaItem>[])
        if (!localFavorites.containsKey(item.key) ||
            !remoteFavorites.containsKey(item.key))
          item.key,
    };
    final removedHistory = {
      for (final item in baseline?.history ?? <HistoryRecord>[])
        if (!localHistory.containsKey(item.key) ||
            !remoteHistory.containsKey(item.key))
          item.key,
    };
    final favorites = {...localFavorites};
    for (final entry in remoteFavorites.entries) {
      final current = favorites[entry.key];
      favorites[entry.key] = current == null
          ? entry.value
          : _metadata(current, entry.value);
    }
    favorites.removeWhere((key, _) => removedFavorites.contains(key));
    final history = {...localHistory};
    for (final entry in remoteHistory.entries) {
      final current = history[entry.key];
      history[entry.key] = current == null
          ? entry.value
          : _mergeHistory(current, entry.value);
    }
    history.removeWhere((key, _) => removedHistory.contains(key));
    return LibraryBackup._(
      exportedAt: DateTime.now().toUtc(),
      favorites: favorites.values,
      history: history.values.map((record) {
        final favorite = favorites[record.key];
        return favorite == null
            ? record
            : record.copyWith(
                item: _metadata(record.item ?? favorite, favorite),
              );
      }),
      excludedLocalFavorites: local.excludedLocalFavorites,
      excludedLocalHistory: local.excludedLocalHistory,
    );
  }

  /// Replace only portable records after a validated cloud download. Local
  /// files and their progress remain device-specific. Roll back both boxes
  /// together if persistence fails, just as with manual imports.
  Future<void> applySynchronized() async {
    final favoriteBox = Storage.favoritesBox;
    final historyBox = Storage.historyBox;
    final favoriteWrites = {
      for (final item in favorites.reversed) item.key: item.toJson(),
    };
    final historyWrites = {for (final item in history) item.key: item.toJson()};
    final favoriteDeletes = favoriteBox.keys
        .whereType<String>()
        .where(
          (key) => _package(key) != 'local' && !favoriteWrites.containsKey(key),
        )
        .toList();
    final historyDeletes = historyBox.keys
        .whereType<String>()
        .where(
          (key) => _package(key) != 'local' && !historyWrites.containsKey(key),
        )
        .toList();
    final oldFavorites = {
      for (final key in {...favoriteWrites.keys, ...favoriteDeletes})
        key: favoriteBox.get(key),
    };
    final oldHistory = {
      for (final key in {...historyWrites.keys, ...historyDeletes})
        key: historyBox.get(key),
    };
    try {
      await favoriteBox.deleteAll(favoriteDeletes);
      await historyBox.deleteAll(historyDeletes);
      await favoriteBox.putAll(favoriteWrites);
      await historyBox.putAll(historyWrites);
      await favoriteBox.flush();
      await historyBox.flush();
    } catch (_) {
      await favoriteBox.deleteAll(
        oldFavorites.keys.where((key) => oldFavorites[key] == null),
      );
      await historyBox.deleteAll(
        oldHistory.keys.where((key) => oldHistory[key] == null),
      );
      await favoriteBox.putAll({
        for (final e in oldFavorites.entries)
          if (e.value != null) e.key: e.value,
      });
      await historyBox.putAll({
        for (final e in oldHistory.entries)
          if (e.value != null) e.key: e.value,
      });
      rethrow;
    }
  }

  /// All fields are checked before any storage write. Do not use the models'
  /// permissive extension parsers on data coming from an external file.
  static LibraryBackup decode(List<int> bytes) {
    _checkSize(bytes.length);
    dynamic decoded;
    try {
      var text = utf8.decode(bytes);
      if (text.startsWith('\uFEFF')) text = text.substring(1);
      decoded = jsonDecode(text);
    } on FormatException {
      throw const FormatException('文件不是有效的 UTF-8 JSON，请选择导出的 JSON 文件。');
    }
    final json = _map(decoded, '文件');
    if (json['format'] != 'FusionReader.library') {
      throw const FormatException('这不是 FusionReader 的书架与历史备份文件。');
    }
    if (json['schemaVersion'] is! int ||
        json['schemaVersion'] != schemaVersion) {
      throw const FormatException('暂不支持此备份版本，请更新应用后重试。');
    }
    final date = DateTime.tryParse(_string(json, 'exportedAt'));
    if (date == null) throw const FormatException('备份的导出时间无效。');
    final rawFavorites = _list(json['favorites'], '书架');
    final rawHistory = _list(json['history'], '历史');
    if (rawFavorites.length + rawHistory.length > maxRecords) {
      throw const FormatException('备份记录过多，最多支持 50000 条。');
    }

    final favorites = <String, MediaItem>{};
    var excludedFavorites = _integer(
      json,
      'excludedLocalFavorites',
      optional: true,
    );
    var excludedHistory = _integer(
      json,
      'excludedLocalHistory',
      optional: true,
    );
    for (final raw in rawFavorites) {
      final item = _item(raw);
      if (item.package == 'local') {
        excludedFavorites++;
        continue;
      }
      final previous = favorites[item.key];
      favorites[item.key] = previous == null ? item : _metadata(previous, item);
    }
    final history = <String, HistoryRecord>{};
    for (final raw in rawHistory) {
      final json = _map(raw, '历史记录');
      final key = _string(json, 'key', requiredValue: true);
      _validateKey(key);
      final item = json['item'] == null ? null : _item(json['item']);
      if (item != null && item.key != key) {
        throw const FormatException('历史记录与作品信息不匹配。');
      }
      final record = HistoryRecord(
        key: key,
        item: item,
        episodeUrl: _string(json, 'episodeUrl'),
        episodeName: _string(json, 'episodeName'),
        groupIndex: _integer(json, 'groupIndex'),
        episodeIndex: _integer(json, 'episodeIndex'),
        timestamp: _integer(json, 'timestamp', maxValue: 253402300799999),
        position: _integer(json, 'position', optional: true),
        textOffset: _integer(json, 'textOffset', optional: true),
      );
      if (_package(key) == 'local') {
        excludedHistory++;
        continue;
      }
      final previous = history[key];
      history[key] = previous == null
          ? record
          : _mergeHistory(previous, record);
    }
    return LibraryBackup._(
      exportedAt: date.toUtc(),
      favorites: favorites.values,
      history: history.values.map((record) {
        final item = favorites[record.key];
        return item == null
            ? record
            : record.copyWith(item: _metadata(record.item ?? item, item));
      }),
      excludedLocalFavorites: excludedFavorites,
      excludedLocalHistory: excludedHistory,
    );
  }

  /// Merge against storage at confirmation time, not the earlier preview.
  /// A repeated import is idempotent; older files cannot rewind progress.
  Future<LibraryImportResult> merge() async {
    final favoritesBox = Storage.favoritesBox;
    final historyBox = Storage.historyBox;
    final favoriteWrites = <String, dynamic>{};
    final historyWrites = <String, dynamic>{};
    var addedFavorites = 0;
    var updatedFavorites = 0;
    var addedHistory = 0;
    var updatedHistory = 0;
    // Hive stores shelf entries oldest first; the exported shelf is newest first.
    for (final incoming in favorites.reversed) {
      final raw = favoritesBox.get(incoming.key);
      final current = raw is Map ? MediaItem.fromJson(raw) : null;
      final item = current == null ? incoming : _metadata(current, incoming);
      if (current == null) {
        addedFavorites++;
      } else if (jsonEncode(item.toJson()) == jsonEncode(current.toJson())) {
        continue;
      } else {
        updatedFavorites++;
      }
      favoriteWrites[item.key] = item.toJson();
    }
    for (final incoming in history) {
      final raw = historyBox.get(incoming.key);
      final current = raw is Map ? HistoryRecord.fromJson(raw) : null;
      var record = current == null
          ? incoming
          : _mergeHistory(current, incoming);
      final favorite =
          favoriteWrites[record.key] ?? favoritesBox.get(record.key);
      if (favorite is Map) {
        final item = MediaItem.fromJson(favorite);
        record = record.copyWith(item: _metadata(record.item ?? item, item));
      }
      if (current == null) {
        addedHistory++;
      } else if (jsonEncode(record.toJson()) == jsonEncode(current.toJson())) {
        continue;
      } else {
        updatedHistory++;
      }
      historyWrites[record.key] = record.toJson();
    }

    // Hive has no transaction spanning two boxes. Keep the affected values so
    // a failed write can undo the merge without touching unrelated records.
    final oldFavorites = {
      for (final key in favoriteWrites.keys) key: favoritesBox.get(key),
    };
    final oldHistory = {
      for (final key in historyWrites.keys) key: historyBox.get(key),
    };
    try {
      await favoritesBox.putAll(favoriteWrites);
      await historyBox.putAll(historyWrites);
      await favoritesBox.flush();
      await historyBox.flush();
    } catch (_) {
      await favoritesBox.deleteAll(
        oldFavorites.keys.where((key) => oldFavorites[key] == null),
      );
      await historyBox.deleteAll(
        oldHistory.keys.where((key) => oldHistory[key] == null),
      );
      await favoritesBox.putAll({
        for (final entry in oldFavorites.entries)
          if (entry.value != null) entry.key: entry.value,
      });
      await historyBox.putAll({
        for (final entry in oldHistory.entries)
          if (entry.value != null) entry.key: entry.value,
      });
      rethrow;
    }
    return LibraryImportResult(
      addedFavorites: addedFavorites,
      updatedFavorites: updatedFavorites,
      addedHistory: addedHistory,
      updatedHistory: updatedHistory,
    );
  }

  static HistoryRecord _mergeHistory(
    HistoryRecord current,
    HistoryRecord incoming,
  ) {
    final newer = incoming.timestamp > current.timestamp ? incoming : current;
    final older = identical(newer, incoming) ? current : incoming;
    // Visiting a title without reading it must not erase the other device's
    // saved chapter. Preserve recency separately from its reading position.
    final progress = newer.hasProgress
        ? newer
        : older.hasProgress
        ? older
        : newer;
    final item = newer.item ?? older.item;
    return HistoryRecord(
      key: newer.key,
      item: item == null ? null : _metadata(item, older.item ?? item),
      episodeUrl: progress.episodeUrl,
      episodeName: progress.episodeName,
      groupIndex: progress.groupIndex,
      episodeIndex: progress.episodeIndex,
      position: progress.position,
      textOffset: progress.textOffset,
      timestamp: newer.timestamp,
    );
  }

  static MediaItem _metadata(MediaItem preferred, MediaItem fallback) =>
      MediaItem(
        package: preferred.package,
        type: preferred.type,
        url: preferred.url,
        title: preferred.title.isNotEmpty ? preferred.title : fallback.title,
        cover: preferred.cover.isNotEmpty ? preferred.cover : fallback.cover,
        update: preferred.update.isNotEmpty
            ? preferred.update
            : fallback.update,
      );

  static MediaItem _item(dynamic raw) {
    final json = _map(raw, '作品');
    final package = _string(json, 'package', requiredValue: true);
    if (package.contains('|') || package.trim() != package) {
      throw const FormatException('作品的来源标识无效。');
    }
    final type = _string(json, 'type', requiredValue: true);
    if (!MediaType.values.any((value) => value.name == type)) {
      throw const FormatException('作品类型无效。');
    }
    return MediaItem(
      package: package,
      type: MediaType.fromString(type),
      title: _string(json, 'title'),
      url: _string(json, 'url', requiredValue: true),
      cover: _string(json, 'cover', optional: true),
      update: _string(json, 'update', optional: true),
    );
  }

  static String _package(String key) => key.split('|').first;

  static void _validateKey(String key) {
    final separator = key.indexOf('|');
    if (separator <= 0 ||
        separator == key.length - 1 ||
        _package(key).trim() != _package(key)) {
      throw const FormatException('历史记录的作品标识无效。');
    }
  }

  static void _checkSize(int length) {
    if (length > maxBytes) throw const FormatException('备份文件超过 20 MB，请拆分后重试。');
  }

  static Map _map(dynamic raw, String label) {
    if (raw is! Map) throw FormatException('$label 格式错误。');
    return raw;
  }

  static List _list(dynamic raw, String label) {
    if (raw is! List) throw FormatException('$label 格式错误。');
    return raw;
  }

  static String _string(
    Map json,
    String key, {
    bool optional = false,
    bool requiredValue = false,
  }) {
    final value = json[key];
    if (optional && value == null) return '';
    if (value is! String ||
        value.length > 131072 ||
        (requiredValue && value.trim().isEmpty)) {
      throw FormatException('备份字段 $key 无效。');
    }
    return value;
  }

  static int _integer(
    Map json,
    String key, {
    bool optional = false,
    int maxValue = 9007199254740991,
  }) {
    final value = json[key];
    if (optional && value == null) return 0;
    if (value is! int || value < 0 || value > maxValue) {
      throw FormatException('备份字段 $key 必须为非负整数。');
    }
    return value;
  }
}

class LibraryImportResult {
  final int addedFavorites;
  final int updatedFavorites;
  final int addedHistory;
  final int updatedHistory;

  const LibraryImportResult({
    required this.addedFavorites,
    required this.updatedFavorites,
    required this.addedHistory,
    required this.updatedHistory,
  });

  String get summary =>
      '新增收藏 $addedFavorites 项，补全收藏 $updatedFavorites 项；'
      '新增历史 $addedHistory 条，更新历史 $updatedHistory 条。';
}
