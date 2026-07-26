import 'dart:io';

// cookie_jar also exports a `Storage`; only the jar itself is needed here.
import 'package:cookie_jar/cookie_jar.dart' show CookieJar;
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

import 'storage.dart';

const kDefaultUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

/// How a given source reaches the network.
///
/// Chinese sites usually reject traffic coming from a foreign proxy exit,
/// while sites blocked in mainland China only work through one — so routing
/// has to be decided per source, not globally.
enum NetMode {
  /// Follow the global proxy setting.
  auto,

  /// Always bypass any proxy.
  direct,

  /// Always go through the configured proxy.
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

  String get label {
    switch (this) {
      case NetMode.auto:
        return '跟随全局';
      case NetMode.direct:
        return '强制直连';
      case NetMode.proxy:
        return '强制代理';
    }
  }
}

class Network {
  static Dio? _proxied;
  static Dio? _direct;

  /// The proxy in use: explicit setting first, then environment variables.
  static String resolvedProxy() {
    final manual = Storage.proxy.trim();
    if (manual.isNotEmpty) return manual;
    final env = Platform.environment;
    final raw = env['HTTPS_PROXY'] ??
        env['https_proxy'] ??
        env['HTTP_PROXY'] ??
        env['http_proxy'] ??
        '';
    return raw.replaceFirst(RegExp(r'^https?://'), '').trim();
  }

  /// Defaults declared by extensions via `@network`, seeded at load time.
  static final Map<String, NetMode> declaredModes = {};

  /// Resolve the effective mode for a source: user override beats the
  /// extension's declared default, which beats plain auto.
  static NetMode modeFor(String package) {
    final override = Storage.extNetMode(package);
    if (override != null) return NetMode.fromString(override);
    return declaredModes[package] ?? NetMode.auto;
  }

  /// True when requests for [package] should go through a proxy, unless the
  /// caller supplies a per-result [override] such as a watch() netMode.
  static bool usesProxyFor(String package, {String? override}) {
    if (override == 'direct') return false;
    if (override == 'proxy') return resolvedProxy().isNotEmpty;
    switch (modeFor(package)) {
      case NetMode.direct:
        return false;
      case NetMode.proxy:
        return resolvedProxy().isNotEmpty;
      case NetMode.auto:
        return resolvedProxy().isNotEmpty;
    }
  }

  /// Dio configured for the given source's routing.
  static Dio forPackage(String package) =>
      usesProxyFor(package) ? proxied : direct;

  static Dio get proxied => _proxied ??= _build(useProxy: true);
  static Dio get direct => _direct ??= _build(useProxy: false);

  /// Drop cached clients so a changed proxy setting takes effect.
  static void reload() {
    _proxied?.close(force: true);
    _direct?.close(force: true);
    _proxied = null;
    _direct = null;
  }

  static Dio _build({required bool useProxy}) {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 40),
      headers: {'User-Agent': kDefaultUserAgent},
      validateStatus: (s) => s != null && s < 400,
      followRedirects: true,
    ));
    // Some sites gate content behind a session cookie handed out on an earlier
    // page view, so cookies have to persist across requests.
    dio.interceptors.add(CookieManager(CookieJar()));

    final adapter = IOHttpClientAdapter();
    adapter.createHttpClient = () {
      final client = HttpClient();
      final proxy = useProxy ? resolvedProxy() : '';
      // An empty findProxy result means DIRECT, which is what we want when
      // bypassing — never fall through to HttpClient's env-var default.
      client.findProxy = (_) => proxy.isEmpty ? 'DIRECT' : 'PROXY $proxy';
      client.badCertificateCallback = (cert, host, port) => true;
      return client;
    };
    dio.httpClientAdapter = adapter;
    return dio;
  }
}
