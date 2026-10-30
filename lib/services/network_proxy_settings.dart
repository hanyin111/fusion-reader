import 'dart:io';

import 'network.dart';
import 'proxy_resolver.dart';
import 'storage.dart';

/// Device-local connection settings, excluded from reader profiles and backups.
class NetworkProxySettings {
  static const storageKey = 'network.manualHttpProxy';

  static String get address => systemProxyResolver.manualAddress;

  static void initialize() {
    final raw = Storage.setting(storageKey);
    final address = raw is String ? normalizeManualHttpProxy(raw) : null;
    systemProxyResolver.setManualAddress(address ?? '');
  }

  static Future<void> save(String value) async {
    final address = normalizeManualHttpProxy(value);
    if (address == null) throw const FormatException('请输入有效的 HTTP 代理地址和端口');
    await Storage.setSetting(storageKey, address);
    systemProxyResolver.setManualAddress(address);
    Network.reload();
  }

  /// Check an explicit HTTP CONNECT proxy without changing saved settings.
  static Future<void> test(String value) async {
    final address = normalizeManualHttpProxy(value);
    if (address == null || address.isEmpty) {
      throw const FormatException('请先填写 HTTP 代理地址和端口');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..findProxy = (_) => 'PROXY $address';
    try {
      final request = await client
          .getUrl(Uri.https('www.cloudflare.com', '/cdn-cgi/trace'))
          .timeout(const Duration(seconds: 10));
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('代理测试返回 HTTP ${response.statusCode}');
      }
      await response.drain<void>().timeout(const Duration(seconds: 10));
    } finally {
      client.close(force: true);
    }
  }
}
