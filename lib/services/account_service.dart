import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'account_api.dart';
import 'library_backup.dart';

abstract interface class AccountSessionStore {
  Future<AccountSession?> read();
  Future<void> write(AccountSession session);
  Future<void> clear();
}

class SecureAccountSessionStore implements AccountSessionStore {
  final String serviceId;
  final FlutterSecureStorage _storage;
  final String key;
  SecureAccountSessionStore(
    this.serviceId, {
    FlutterSecureStorage? storage,
    this.key = 'fusion_account_session_v1',
  }) : _storage =
           storage ??
           const FlutterSecureStorage(
             aOptions: AndroidOptions(encryptedSharedPreferences: true),
             iOptions: IOSOptions(
               accessibility: KeychainAccessibility.first_unlock_this_device,
             ),
           );

  @override
  Future<AccountSession?> read() async {
    final text = await _storage.read(key: key);
    if (text == null) return null;
    try {
      final json = jsonDecode(text);
      if (json is! Map || json['service'] != serviceId) return null;
      return AccountSession.fromJson(json['session']);
    } on FormatException {
      await clear();
      return null;
    }
  }

  @override
  Future<void> write(AccountSession session) => _storage.write(
    key: key,
    value: jsonEncode({'service': serviceId, 'session': session.toJson()}),
  );
  @override
  Future<void> clear() => _storage.delete(key: key);
}

class AccountSyncState {
  final LibraryBackup snapshot;
  final DateTime syncedAt;
  const AccountSyncState(this.snapshot, this.syncedAt);
}

abstract interface class AccountLibraryStore {
  LibraryBackup capture();
  Future<void> apply(LibraryBackup snapshot);
  Future<AccountSyncState?> baseline(String owner);
  Future<void> saveBaseline(String owner, AccountSyncState state);
}

class HiveAccountLibraryStore implements AccountLibraryStore {
  Future<Box> _box() => Hive.isBoxOpen('account_sync')
      ? Future.value(Hive.box('account_sync'))
      : Hive.openBox('account_sync');
  @override
  LibraryBackup capture() => LibraryBackup.capture();
  @override
  Future<void> apply(LibraryBackup snapshot) => snapshot.applySynchronized();
  @override
  Future<AccountSyncState?> baseline(String owner) async {
    final raw = (await _box()).get(owner);
    if (raw == null) return null;
    try {
      if (raw is! Map ||
          raw['snapshot'] is! String ||
          raw['syncedAt'] is! String) {
        throw const FormatException();
      }
      final date = DateTime.tryParse(raw['syncedAt']);
      if (date == null) {
        throw const FormatException();
      }
      return AccountSyncState(
        LibraryBackup.decode(utf8.encode(raw['snapshot'])),
        date.toUtc(),
      );
    } on FormatException {
      // A corrupt ancestor must not turn into a first sync and resurrect removals.
      throw const AccountException('本机同步记录损坏，请先导出数据备份，再联系维护者。');
    }
  }

  @override
  Future<void> saveBaseline(String owner, AccountSyncState state) async {
    final box = await _box();
    await box.put(owner, {
      'snapshot': utf8.decode(state.snapshot.encodeBytes()),
      'syncedAt': state.syncedAt.toUtc().toIso8601String(),
    });
    await box.flush();
  }
}

class AccountService extends ChangeNotifier {
  static final instance = AccountService();
  final AccountApi api;
  final AccountSessionStore sessions;
  final AccountLibraryStore library;
  AccountSession? session;
  DateTime? lastSync;
  bool busy = false;
  bool initialized = false;
  String? error;
  Future<void>? _initializing;

  AccountService({
    AccountApi? api,
    AccountSessionStore? sessions,
    AccountLibraryStore? library,
  }) : api = api ?? HttpAccountApi(),
       sessions =
           sessions ??
           SecureAccountSessionStore((api ?? HttpAccountApi()).serviceId),
       library = library ?? HiveAccountLibraryStore();

  bool get configured => api.configured;
  String _owner(AccountSession current) => sha256
      .convert(utf8.encode('${api.serviceId}\n${current.userId}'))
      .toString();

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    try {
      final saved = await sessions.read();
      if (saved != null && saved.expiresAt.isAfter(DateTime.now())) {
        session = saved;
        lastSync = (await library.baseline(_owner(saved)))?.syncedAt;
      } else if (saved != null) {
        await sessions.clear();
      }
    } catch (e) {
      error = e is AccountException ? e.message : '无法读取安全存储，可以尝试重新登录。';
    } finally {
      initialized = true;
      notifyListeners();
    }
  }

  static String? validateUsername(String value) =>
      RegExp(r'^[a-z0-9_]{3,32}$').hasMatch(value.trim().toLowerCase())
      ? null
      : '用户名为 3–32 位字母、数字或下划线';
  static String? validatePassword(String value) =>
      value.length >= 8 && value.length <= 128 ? null : '密码需要 8–128 个字符';

  Future<bool> authenticate(
    String username,
    String password, {
    String? activationCode,
  }) async {
    await initialize();
    if (busy) return false;
    error = validateUsername(username) ?? validatePassword(password);
    if (activationCode != null &&
        (activationCode.trim().isEmpty || activationCode.trim().length > 128)) {
      error = '请填写有效的激活码。';
    }
    if (error != null) {
      notifyListeners();
      return false;
    }
    return _operation(() async {
      final next = await api.authenticate(
        username.trim().toLowerCase(),
        password,
        activationCode: activationCode?.trim(),
      );
      // Do not claim login success if the OS cannot retain the token securely.
      try {
        await sessions.write(next);
        final saved = await sessions.read();
        if (saved?.token != next.token || saved?.userId != next.userId) {
          throw StateError('Session was not retained');
        }
      } catch (_) {
        throw AccountException(
          activationCode == null
              ? '无法安全保存登录状态，请检查系统安全存储后重试。'
              : '账号已注册，但无法安全保存登录状态。请修复系统安全存储后改用登录。',
        );
      }
      session = next;
      lastSync = (await library.baseline(_owner(next)))?.syncedAt;
    });
  }

  Future<bool> uploadToCloud({bool includeReaderSettings = true}) =>
      _sync(upload: true, includeReaderSettings: includeReaderSettings);
  Future<bool> downloadToLocal({bool includeReaderSettings = true}) =>
      _sync(upload: false, includeReaderSettings: includeReaderSettings);

  String _contents(LibraryBackup snapshot, bool includeReaderSettings) =>
      jsonEncode({
        'favorites': snapshot.favorites.map((e) => e.toJson()).toList(),
        'history': snapshot.history.map((e) => e.toJson()).toList(),
        if (includeReaderSettings)
          'readerSettings': snapshot.currentReaderSettings,
      });

  Future<bool> _sync({
    required bool upload,
    required bool includeReaderSettings,
  }) async {
    await initialize();
    if (busy) return false;
    final current = session;
    if (current == null) {
      error = '请先登录。';
      notifyListeners();
      return false;
    }
    return _operation(() async {
      if (!current.expiresAt.isAfter(DateTime.now())) {
        throw const AccountException('登录已失效，请重新登录。', expired: true);
      }
      final owner = _owner(current);
      final before = library.capture();
      before.encodeBytes();
      final cloud = await api.download(current.token);
      final accepted = upload
          ? before.withReaderSettings({
              ...cloud.snapshot.readerSettings,
              if (includeReaderSettings) ...before.readerSettings,
            })
          : includeReaderSettings
          ? cloud.snapshot
          : cloud.snapshot.withReaderSettings({});
      accepted.encodeBytes();
      if (upload) {
        try {
          await api.upload(current.token, cloud.revision, accepted);
        } on AccountException catch (e) {
          if (e.conflict) {
            throw const AccountException('云端已被其他设备更新，请重新确认“本地同步云端”。');
          }
          rethrow;
        }
        // Uploading must never write back remote records or undo local edits.
      } else {
        if (_contents(before, includeReaderSettings) !=
            _contents(library.capture(), includeReaderSettings)) {
          throw const AccountException('下载期间本机数据发生变化，请重新确认“云端同步本地”。');
        }
        await library.apply(accepted);
      }
      final now = DateTime.now().toUtc();
      try {
        await library.saveBaseline(owner, AccountSyncState(accepted, now));
      } catch (_) {
        throw AccountException(
          upload ? '上传已完成，但本机同步时间保存失败。' : '下载已完成，但本机同步时间保存失败。',
        );
      }
      lastSync = now;
    });
  }

  Future<bool> logout() async {
    await initialize();
    if (busy) return false;
    return _operation(() async {
      final token = session?.token;
      try {
        await sessions.clear();
      } catch (_) {
        throw const AccountException('无法清除安全存储，退出失败，请重试。');
      }
      session = null;
      lastSync = null;
      // Signing out works offline. Remote sessions also have a fixed expiry.
      if (token != null) {
        try {
          await api.logout(token);
        } catch (_) {
          /* Local logout already complete. */
        }
      }
    });
  }

  Future<bool> _operation(Future<void> Function() action) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await action();
      return true;
    } catch (e) {
      error = e is AccountException
          ? e.message
          : e is FormatException
          ? e.message.toString()
          : '操作未完成，请稍后重试。';
      if (e is AccountException && e.expired) {
        session = null;
        lastSync = null;
        try {
          await sessions.clear();
        } catch (_) {
          /* Expired tokens cannot authenticate. */
        }
      }
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}
