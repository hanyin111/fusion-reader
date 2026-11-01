import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// One opaque local credential per installed source; excluded from backups and
/// cloud-library payloads. Native keys are never supplied by source scripts.
class ExtensionCredentials {
  static final instance = ExtensionCredentials();
  final FlutterSecureStorage storage;
  final Map<String, Future<void>> _pending = {};

  ExtensionCredentials({FlutterSecureStorage? storage})
    : storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  String _key(String package) {
    if (!RegExp(r'^[a-z][a-z0-9_.-]{0,127}$').hasMatch(package)) {
      throw const FormatException('来源标识不正确');
    }
    return 'fusion_extension_session_v1.$package';
  }

  Future<String?> read(String package) async {
    final key = _key(package);
    await _pending[key]?.catchError((Object _) {});
    return storage.read(key: key);
  }

  Future<void> write(String package, String? value) {
    final key = _key(package);
    if (value != null && value.length > 16384) {
      throw const FormatException('来源登录信息过大');
    }
    late Future<void> operation;
    operation = (_pending[key] ?? Future.value())
        .catchError((Object _) {})
        .then((_) async {
          if (value == null) {
            await storage.delete(key: key);
          } else {
            await storage.write(key: key, value: value);
          }
          if (await storage.read(key: key) != value) {
            throw StateError('来源登录信息未能保存');
          }
        })
        .whenComplete(() {
          if (identical(_pending[key], operation)) _pending.remove(key);
        });
    _pending[key] = operation;
    return operation;
  }

  Future<void> clear(String package) => write(package, null);
}
