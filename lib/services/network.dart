import 'dart:io';

// cookie_jar also exports a `Storage`; only the jar itself is needed here.
import 'package:cookie_jar/cookie_jar.dart' show CookieJar;
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter/foundation.dart';

import 'apple_http_adapter.dart';
import 'proxy_resolver.dart';

const kDefaultUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

/// How a given source reaches the network.
///
/// Chinese sites usually reject traffic coming from a foreign proxy exit,
/// while sites blocked in mainland China only work through one — so routing
/// has to be decided per source, not globally.
enum NetMode {
  /// Follow the system proxy and process environment.
  auto,

  /// Always bypass any proxy.
  direct,

  /// Use the system/environment proxy when one is available.
  proxy;

  static NetMode fromString(String? s) {
    switch (s) {
      case 'direct':
        return NetMode.direct;
      case 'proxy':
        return NetMode.proxy;
      default:
        return NetMode.auto;
    }
  }
}

class Network {
  static Dio? _proxied;
  static Dio? _direct;

  static SystemProxyResolver _proxyResolver = systemProxyResolver;

  static Future<void> prepare() => _proxyResolver.refresh();

  static String resolvedProxy({Uri? uri}) => _proxyResolver.addressFor(uri);

  @visibleForTesting
  static void setProxyResolverForTesting(SystemProxyResolver? resolver) {
    reload();
    _proxyResolver = resolver ?? systemProxyResolver;
  }

  /// Defaults declared by extensions via `@network`, seeded at load time.
  static final Map<String, NetMode> declaredModes = {};

  /// Internal source compatibility defaults, with no stored user overrides.
  static NetMode modeFor(String package) {
    return declaredModes[package] ?? NetMode.auto;
  }

  /// True when requests for [package] should go through a proxy, unless the
  /// caller supplies a per-result [override] such as a watch() netMode.
  static bool usesProxyFor(String package, {String? override, Uri? uri}) {
    return _routeFor(package, override) != NetMode.direct &&
        resolvedProxy(uri: uri).isNotEmpty;
  }

  static NetMode _routeFor(String package, String? override) =>
      override == 'direct' || override == 'proxy' || override == 'auto'
      ? NetMode.fromString(override)
      : modeFor(package);

  /// Dio configured for the given source's routing.
  static Dio forPackage(String package, {String? override}) {
    final mode = _routeFor(package, override);
    // Reading system settings is asynchronous. Do not choose DIRECT just
    // because the first request arrived before proxy discovery finished.
    return mode == NetMode.direct ? direct : proxied;
  }

  static Dio get proxied => _proxied ??= _build(useProxy: true);
  static Dio get direct => _direct ??= _build(useProxy: false);

  /// Drop cached clients and active connections.
  static void reload() {
    _proxied?.close(force: true);
    _direct?.close(force: true);
    _proxied = null;
    _direct = null;
    _proxyResolver.invalidate();
  }

  static Dio _build({required bool useProxy}) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 40),
        headers: {'User-Agent': kDefaultUserAgent},
        validateStatus: (s) => s != null && s < 400,
        followRedirects: true,
      ),
    );
    // Some sites gate content behind a session cookie handed out on an earlier
    // page view, so cookies have to persist across requests.
    dio.interceptors.add(CookieManager(CookieJar()));
    if (useProxy && Platform.isIOS) {
      // Native URLSession follows Apple's active system proxy/VPN rules.
      // The manual endpoint resolver remains available for socket-based media.
      dio.httpClientAdapter = AppleHttpAdapter();
      return dio;
    }
    if (useProxy) {
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            await prepare();
            handler.next(options);
          },
        ),
      );
    }

    final adapter = IOHttpClientAdapter();
    adapter.createHttpClient = () {
      final client = HttpClient();
      // An empty findProxy result means DIRECT, which is what we want when
      // bypassing — never fall through to HttpClient's env-var default.
      client.findProxy = (uri) =>
          useProxy ? _proxyResolver.findProxy(uri) : 'DIRECT';
      return client;
    };
    dio.httpClientAdapter = adapter;
    return dio;
  }
}
