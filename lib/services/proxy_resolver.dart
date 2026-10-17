import 'dart:io';

import 'package:flutter/services.dart';

/// A manual HTTP CONNECT proxy supplied by the operating system.
class SystemProxySettings {
  final String http;
  final String https;
  final List<String> bypass;

  const SystemProxySettings({
    this.http = '',
    this.https = '',
    this.bypass = const [],
  });

  factory SystemProxySettings.fromMap(Map values) => SystemProxySettings(
    http: _address('${values['http'] ?? ''}'),
    https: _address('${values['https'] ?? ''}'),
    bypass: (values['bypass'] as List? ?? const [])
        .whereType<String>()
        .toList(),
  );

  factory SystemProxySettings.fromWindowsRegistry(String text) {
    String value(String name) =>
        RegExp(
          '$name\\s+REG_SZ\\s+([^\\r\\n]+)',
        ).firstMatch(text)?.group(1)?.trim() ??
        '';
    if (!RegExp(r'ProxyEnable\s+REG_DWORD\s+0x1\b').hasMatch(text)) {
      return const SystemProxySettings();
    }
    final server = value('ProxyServer');
    var http = server;
    var https = server;
    if (server.contains('=')) {
      final entries = <String, String>{};
      for (final part in server.split(';')) {
        final separator = part.indexOf('=');
        if (separator > 0) {
          entries[part.substring(0, separator).trim().toLowerCase()] = part
              .substring(separator + 1)
              .trim();
        }
      }
      http = entries['http'] ?? entries['https'] ?? '';
      https = entries['https'] ?? entries['http'] ?? '';
    }
    return SystemProxySettings(
      http: _address(http),
      https: _address(https),
      bypass: value('ProxyOverride').split(';'),
    );
  }
}

String _address(String raw) {
  raw = raw.trim();
  if (raw.isEmpty) return '';
  final uri = Uri.tryParse(raw.contains('://') ? raw : 'http://$raw');
  if (uri == null ||
      uri.scheme != 'http' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.port < 1 ||
      uri.port > 65535) {
    return '';
  }
  final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
  return '$host:${uri.port}';
}

bool _bypassed(Uri uri, Iterable<String> patterns) {
  final host = uri.host.toLowerCase();
  for (var pattern in patterns) {
    pattern = pattern.trim().toLowerCase();
    if (pattern.isEmpty) continue;
    if (pattern == '<local>') {
      if (!host.contains('.') && !host.contains(':')) return true;
    } else if (pattern.startsWith('.')) {
      if (host == pattern.substring(1) || host.endsWith(pattern)) return true;
    } else if (pattern.contains('*')) {
      final regex = RegExp(
        '^${RegExp.escape(pattern).replaceAll(r'\*', '.*')}\$',
      );
      if (regex.hasMatch(host)) return true;
    } else if (host == pattern || host.endsWith('.$pattern')) {
      return true;
    }
  }
  return false;
}

/// Batch local proxy lookups, without blocking startup or querying for each
/// image. Changes are picked up on later requests, without restarting the app.
class SystemProxyResolver {
  static const channel = MethodChannel('fusion_reader/system_proxy');
  final Map<String, String> environment;
  final Future<SystemProxySettings> Function() _loadSettings;
  final Duration refreshInterval;
  SystemProxySettings _settings = const SystemProxySettings();
  Future<void>? _refreshing;
  DateTime? _checked;

  SystemProxyResolver({
    Map<String, String>? environment,
    Future<SystemProxySettings> Function()? loadSettings,
    this.refreshInterval = const Duration(seconds: 5),
  }) : environment = environment ?? Platform.environment,
       _loadSettings = loadSettings ?? _platformSettings;

  static Future<SystemProxySettings> _platformSettings() async {
    if (Platform.isIOS) {
      final values = await channel.invokeMapMethod<String, dynamic>('settings');
      return SystemProxySettings.fromMap(values ?? const {});
    }
    if (!Platform.isWindows) return const SystemProxySettings();
    final result = await Process.run(
      '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\reg.exe',
      [
        'query',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
      ],
    ).timeout(const Duration(seconds: 4));
    return result.exitCode == 0
        ? SystemProxySettings.fromWindowsRegistry('${result.stdout}')
        : const SystemProxySettings();
  }

  Future<void> refresh() async {
    if (_refreshing case final pending?) return pending;
    if (_checked != null &&
        DateTime.now().difference(_checked!) < refreshInterval) {
      return;
    }
    final pending = _refresh();
    _refreshing = pending;
    try {
      await pending;
    } finally {
      if (identical(_refreshing, pending)) _refreshing = null;
    }
  }

  Future<void> _refresh() async {
    try {
      _settings = await _loadSettings();
    } catch (_) {
      // Missing OS settings leave the normal OS/VPN route available.
      _settings = const SystemProxySettings();
    } finally {
      _checked = DateTime.now();
    }
  }

  void invalidate() => _checked = null;

  String addressFor([Uri? uri]) {
    final scheme = uri?.scheme ?? 'https';
    if (scheme != 'http' && scheme != 'https') return '';
    final keys = scheme == 'http'
        ? ['http_proxy', 'HTTP_PROXY', 'https_proxy', 'HTTPS_PROXY']
        : ['https_proxy', 'HTTPS_PROXY', 'http_proxy', 'HTTP_PROXY'];
    for (final key in keys) {
      final address = _address(environment[key] ?? '');
      if (address.isEmpty) continue;
      final bypass = environment['no_proxy'] ?? environment['NO_PROXY'] ?? '';
      return uri != null && _bypassed(uri, bypass.split(',')) ? '' : address;
    }
    if (uri != null && _bypassed(uri, _settings.bypass)) return '';
    return scheme == 'https'
        ? (_settings.https.isNotEmpty ? _settings.https : _settings.http)
        : (_settings.http.isNotEmpty ? _settings.http : _settings.https);
  }

  String findProxy(Uri uri) {
    final address = addressFor(uri);
    return address.isEmpty ? 'DIRECT' : 'PROXY $address';
  }
}

final systemProxyResolver = SystemProxyResolver();
