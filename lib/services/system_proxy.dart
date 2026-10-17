import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'apple_http_adapter.dart';
import 'proxy_resolver.dart';

/// Repository and updater requests share the source proxy discovery rules.
Future<void> configureSystemProxy(Dio client) async {
  if (Platform.isIOS) {
    final adapter = client.httpClientAdapter;
    if (adapter is IOHttpClientAdapter) {
      client.httpClientAdapter = AppleHttpAdapter();
      adapter.close();
    }
    return;
  }
  await systemProxyResolver.refresh();
  final adapter = client.httpClientAdapter;
  if (adapter is! IOHttpClientAdapter) return;
  adapter.createHttpClient = () =>
      HttpClient()..findProxy = systemProxyResolver.findProxy;
  client.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) async {
        await systemProxyResolver.refresh();
        handler.next(options);
      },
    ),
  );
}
