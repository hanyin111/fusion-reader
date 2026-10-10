import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// Respect the existing Windows HTTP(S) proxy without disabling TLS validation
/// or adding app preferences. Other systems retain their environment route.
Future<void> configureSystemProxy(Dio client) async {
  if (!Platform.isWindows) return;
  try {
    final result = await Process.run(
      '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\reg.exe',
      [
        'query',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
      ],
    ).timeout(const Duration(seconds: 4));
    final settings = result.stdout.toString();
    if (result.exitCode != 0 ||
        !RegExp(r'ProxyEnable\s+REG_DWORD\s+0x1\b').hasMatch(settings)) {
      return;
    }
    var address = RegExp(
      r'ProxyServer\s+REG_SZ\s+([^\r\n]+)',
    ).firstMatch(settings)?.group(1)?.trim();
    if (address == null) return;
    if (address.contains('=')) {
      final entries = <String, String>{};
      for (final item in address.split(';')) {
        final split = item.indexOf('=');
        if (split > 0) {
          entries[item.substring(0, split).trim().toLowerCase()] = item
              .substring(split + 1)
              .trim();
        }
      }
      address = entries['https'] ?? entries['http'];
    }
    if (address == null) return;
    final uri = Uri.tryParse(
      address.contains('://') ? address : 'http://$address',
    );
    if (uri == null ||
        uri.scheme != 'http' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.path.isNotEmpty) {
      return;
    }
    final proxy =
        '${uri.host.contains(':') ? '[${uri.host}]' : uri.host}:${uri.hasPort ? uri.port : 80}';
    (client.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () =>
        HttpClient()..findProxy = (_) => 'PROXY $proxy';
  } catch (_) {
    // Missing registry keys do not block ordinary environment/direct routing.
  }
}
