import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../models/app_update.dart';
import 'system_proxy.dart';

extension UpdateCancellation on CancelToken {
  void throwIfCancellationRequested() {
    if (isCancelled) throw cancelError!;
  }
}

class AppUpdateApi {
  final Dio client;
  final bool _configure;
  Future<void>? _configuration;
  AppUpdateApi({Dio? client})
    : _configure = client == null,
      client = client ?? _client();

  static Dio _client() {
    final client = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 45),
        followRedirects: false,
        validateStatus: (_) => true,
        headers: {'User-Agent': 'FusionReader-Updater'},
      ),
    );
    final adapter = IOHttpClientAdapter();
    adapter.createHttpClient = () =>
        HttpClient()..findProxy = HttpClient.findProxyFromEnvironment;
    client.httpClientAdapter = adapter;
    return client;
  }

  Future<void> _prepare() async {
    if (_configure) await (_configuration ??= configureSystemProxy(client));
  }

  Future<AppUpdateRelease> latest(
    UpdatePlatform platform, {
    String? abi,
    CancelToken? cancel,
  }) async {
    await _prepare();
    final response = await client.get<ResponseBody>(
      'https://api.github.com/repos/${AppUpdateRelease.repository}/releases/latest',
      cancelToken: cancel,
      options: Options(
        responseType: ResponseType.stream,
        followRedirects: false,
        validateStatus: (_) => true,
        headers: {
          'Accept': 'application/vnd.github+json',
          'Cache-Control': 'no-cache',
        },
      ),
    );
    if (response.statusCode != 200 || response.data == null) {
      if (response.statusCode == 403 || response.statusCode == 429) {
        throw const FormatException('GitHub 请求暂时受限，请稍后再检查。');
      }
      if (response.statusCode == 404) {
        throw const FormatException('暂时没有可用的正式版本。');
      }
      throw const FormatException('检查更新失败，请检查网络后重试。');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.data!.stream) {
      if (bytes.length + chunk.length > 1024 * 1024) {
        throw const FormatException('更新信息过大。');
      }
      bytes.add(chunk);
    }
    return AppUpdateRelease.parse(
      jsonDecode(utf8.decode(bytes.takeBytes())),
      platform,
      abi: abi,
    );
  }

  static bool trustedDownload(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      uri.port == 443 &&
      const [
        'github.com',
        'release-assets.githubusercontent.com',
        'objects.githubusercontent.com',
        'github-releases.githubusercontent.com',
      ].contains(uri.host);

  Future<void> download(
    AppUpdateAsset asset,
    File file, {
    required CancelToken cancel,
    required void Function(int received, int total) progress,
  }) async {
    await _prepare();
    var uri = asset.url;
    Response<ResponseBody>? response;
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (!trustedDownload(uri)) throw const FormatException('更新包下载地址不受信任。');
      response = await client.get<ResponseBody>(
        uri.toString(),
        cancelToken: cancel,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          validateStatus: (_) => true,
          headers: {'Accept': 'application/octet-stream'},
        ),
      );
      if (response.statusCode == 200) break;
      if (!const [301, 302, 303, 307, 308].contains(response.statusCode)) {
        throw const FormatException('更新包下载失败，请稍后重试。');
      }
      final location = response.headers.value('location');
      await response.data?.stream.listen((_) {}).cancel();
      if (location == null || redirects == 5) {
        throw const FormatException('更新包重定向异常。');
      }
      uri = uri.resolve(location);
    }
    final body = response?.data;
    if (body == null) throw const FormatException('更新包返回空内容。');
    final output = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in body.stream) {
        cancel.throwIfCancellationRequested();
        received += chunk.length;
        if (received > asset.size) throw const FormatException('更新包大小不匹配。');
        output.add(chunk);
        progress(received, asset.size);
      }
      await output.flush();
    } finally {
      await output.close();
    }
    cancel.throwIfCancellationRequested();
    if (received != asset.size ||
        (await sha256.bind(file.openRead()).first).toString() !=
            asset.checksum) {
      throw const FormatException('更新包不完整或文件校验失败，请重新检查版本后下载。');
    }
  }

  void close() => client.close(force: true);
}
