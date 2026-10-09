import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../models/models.dart';

const defaultExtensionRepository =
    'https://hanyin111.github.io/fusion-reader-extensions/index.json';

int compareExtensionVersions(String first, String second) {
  List<int> parts(String value) =>
      value.replaceFirst(RegExp(r'^v'), '').split('.').map(int.parse).toList();
  final a = parts(first), b = parts(second);
  for (var i = 0; i < 3; i++) {
    final difference = a[i].compareTo(b[i]);
    if (difference != 0) return difference;
  }
  return 0;
}

bool _version(String value) => RegExp(r'^v?\d+\.\d+\.\d+$').hasMatch(value);

Uri repositoryUri(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw const FormatException('请填写 HTTPS 插件仓库索引地址。');
  }
  return uri;
}

class RepositoryExtension {
  final String package, name, version, lang, checksum, minAppVersion;
  final MediaType type;
  final Uri url;
  final int size;
  const RepositoryExtension({
    required this.package,
    required this.name,
    required this.version,
    required this.lang,
    required this.type,
    required this.url,
    required this.checksum,
    required this.size,
    required this.minAppVersion,
  });

  factory RepositoryExtension.parse(Object? value, Uri index) {
    if (value is! Map) throw const FormatException('插件仓库条目格式不正确。');
    String text(String key) {
      final raw = value[key];
      if (raw is! String || raw.isEmpty || raw.length > 2048) {
        throw const FormatException('插件仓库条目缺少有效字段。');
      }
      return raw;
    }

    final package = text('package'),
        name = text('name'),
        version = text('version');
    final checksum = text('sha256'), kind = text('type');
    final minimum = text('minAppVersion');
    final size = value['size'];
    if (!RegExp(r'^[a-z][a-z0-9_.-]{0,127}$').hasMatch(package) ||
        !_version(version) ||
        !_version(minimum) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(checksum) ||
        !['manga', 'novel', 'anime'].contains(kind) ||
        size is! int ||
        size <= 0 ||
        size > ExtensionRepository.maxScriptBytes) {
      throw const FormatException('插件仓库条目校验失败。');
    }
    final url = repositoryUri(index.resolve(text('url')).toString());
    return RepositoryExtension(
      package: package,
      name: name,
      version: version,
      lang: value['lang'] is String ? value['lang'] : 'all',
      type: MediaType.fromString(kind),
      url: url,
      checksum: checksum,
      size: size,
      minAppVersion: minimum,
    );
  }

  bool supports(String appVersion) =>
      _version(appVersion) &&
      compareExtensionVersions(appVersion, minAppVersion) >= 0;

  bool hasUpdate(String script) {
    final installed = ExtensionMeta.parse(script);
    if (installed == null ||
        installed.package != package ||
        !_version(installed.version)) {
      return false;
    }
    final comparison = compareExtensionVersions(version, installed.version);
    return comparison > 0 ||
        (comparison == 0 &&
            sha256.convert(utf8.encode(script)).toString() != checksum);
  }

  String verify(List<int> bytes) {
    if (bytes.length != size || sha256.convert(bytes).toString() != checksum) {
      throw const FormatException('插件下载不完整或校验失败，原插件未改动。请刷新仓库后重试。');
    }
    final script = utf8.decode(bytes);
    final meta = ExtensionMeta.parse(script);
    if (meta == null ||
        meta.package != package ||
        meta.version != version ||
        meta.name != name ||
        meta.type != type) {
      throw const FormatException('插件脚本与仓库信息不一致，已取消安装。');
    }
    return script;
  }
}

class ExtensionCatalog {
  final String name;
  final List<RepositoryExtension> extensions;
  final Map<String, dynamic> json;
  ExtensionCatalog(this.name, this.extensions, this.json);

  factory ExtensionCatalog.parse(Object? value, Uri index) {
    if (value is! Map ||
        value['schemaVersion'] != 1 ||
        value['name'] is! String ||
        value['extensions'] is! List) {
      throw const FormatException('插件仓库格式或版本不支持。');
    }
    final entries = value['extensions'] as List;
    if (entries.length > 500) throw const FormatException('插件仓库条目过多。');
    final parsed = entries
        .map((e) => RepositoryExtension.parse(e, index))
        .toList();
    if (parsed.map((e) => e.package).toSet().length != parsed.length) {
      throw const FormatException('插件仓库包含重复的来源标识。');
    }
    return ExtensionCatalog(
      value['name'],
      List.unmodifiable(parsed),
      Map<String, dynamic>.from(value),
    );
  }
}

class ExtensionRepository {
  static const maxScriptBytes = 2 * 1024 * 1024;
  final Uri index;
  final Dio client;
  final bool _configureClient;
  Future<void>? _configuration;
  ExtensionRepository({String url = defaultExtensionRepository, Dio? client})
    : index = repositoryUri(url),
      _configureClient = client == null,
      client = client ?? _client();

  static Dio _client() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 25),
        followRedirects: false,
        validateStatus: (status) => status == 200,
      ),
    );
    final adapter = IOHttpClientAdapter();
    adapter.createHttpClient = () =>
        HttpClient()..findProxy = HttpClient.findProxyFromEnvironment;
    dio.httpClientAdapter = adapter;
    return dio;
  }

  Future<void> _configure() async {
    if (!_configureClient || !Platform.isWindows) return;
    // Read the existing Windows proxy without adding application network
    // preferences. No shell is used, and certificate validation stays enabled.
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
      // Platforms without this key still use their environment/default routes.
    }
  }

  Future<Uint8List> _download(Uri uri, int limit) async {
    await (_configuration ??= _configure());
    final cancel = CancelToken();
    try {
      final response = await client.get<ResponseBody>(
        uri.toString(),
        options: Options(
          responseType: ResponseType.stream,
          headers: {'Cache-Control': 'no-cache'},
        ),
        cancelToken: cancel,
      );
      final body = response.data;
      if (body == null) throw const FormatException('插件仓库返回空内容。');
      final builder = BytesBuilder(copy: false);
      await for (final chunk in body.stream) {
        if (builder.length + chunk.length > limit) {
          throw const FormatException('插件仓库或脚本超过大小限制。');
        }
        builder.add(chunk);
      }
      return builder.takeBytes();
    } finally {
      cancel.cancel();
    }
  }

  Future<ExtensionCatalog> fetch() async => ExtensionCatalog.parse(
    jsonDecode(utf8.decode(await _download(index, 512 * 1024))),
    index,
  );

  Future<String> download(RepositoryExtension extension) async =>
      extension.verify(await _download(extension.url, maxScriptBytes));

  Future<String> downloadUrl(String url) async =>
      utf8.decode(await _download(repositoryUri(url), maxScriptBytes));
}
