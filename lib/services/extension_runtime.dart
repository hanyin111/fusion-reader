import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';

import '../models/models.dart';
import 'apple_js_runtime.dart';
import 'browser_loader.dart';
import 'extension_result.dart';
import 'extension_crypto.dart';
import 'extension_grpc.dart';
import 'network.dart';
import 'storage.dart';

export 'extension_result.dart' show ExtensionException;

/// One loaded extension: its own JS runtime plus the Dart bridge.
class ExtensionService {
  final ExtensionMeta meta;
  final String script;
  final String prelude;

  JavascriptRuntime? _rt;
  Future<void>? _initializing;
  bool _ready = false;
  int _generation = 0;
  bool get loaded => _ready;

  ExtensionService({required this.meta, required this.script, required this.prelude});

  Future<void> init() async {
    if (_ready) return;
    final pending = _initializing;
    if (pending != null) return pending;
    final initialization = _initialize();
    _initializing = initialization;
    try {
      await initialization;
    } finally {
      if (identical(_initializing, initialization)) _initializing = null;
    }
  }

  Future<void> _initialize() async {
    final generation = _generation;
    try {
      await _createRuntime();
      if (generation != _generation) {
        throw ExtensionException(meta.package, '扩展加载已取消，请重试');
      }
      _ready = true;
    } catch (_) {
      if (generation == _generation) dispose();
      rethrow;
    }
  }

  Future<void> _createRuntime() async {
    final rt = Platform.isIOS || Platform.isMacOS
        ? AppleJsRuntime()
        : getJavascriptRuntime(xhr: false);
    _rt = rt;

    rt.onMessage('console', (dynamic args) {
      debugPrint('[ext:${meta.package}] ${args['level']}: ${(args['args'] as List).join(' ')}');
      return null;
    });

    _channel(rt, 'request', _handleRequest);
    _channel(rt, 'grpcRequest', (payload) => ExtensionGrpc.request(payload as Map));
    _channel(rt, 'querySelector', _handleQuerySelector);
    _channel(rt, 'querySelectorAll', _handleQuerySelectorAll);
    _channel(rt, 'getAttributeText', _handleGetAttributeText);
    _channel(rt, 'queryXPath', _handleQueryXPath);
    _channel(rt, 'sleep', _handleSleep);
    _channel(rt, 'md5', _handleMd5);
    _channel(rt, 'hmacSha256', _handleHmacSha256);
    _channel(rt, 'base64Encode', _handleBase64Encode);
    _channel(rt, 'aesEcbDecrypt', _handleAesEcbDecrypt);
    _channel(rt, 'registerSetting', _handleRegisterSetting);
    _channel(rt, 'getSetting', _handleGetSetting);
    _channel(rt, 'setSetting', _handleSetSetting);

    final preludeResult = rt.evaluate(prelude);
    if (preludeResult.isError) {
      throw ExtensionException(meta.package, 'runtime prelude failed: ${preludeResult.stringResult}');
    }

    // Strip ES module syntax so the script can run as a plain QuickJS script.
    var src = script.replaceFirst(
      RegExp(r'export\s+default\s+class\s+(\w+\s+)?extends\s+Extension'),
      'globalThis.__ExtClass = class extends Extension',
    );
    final evalResult = rt.evaluate(src);
    if (evalResult.isError) {
      throw ExtensionException(meta.package, 'script eval failed: ${evalResult.stringResult}');
    }

    final instResult = rt.evaluate('''
globalThis.__ext = new globalThis.__ExtClass();
__ext.package = ${jsonEncode(meta.package)};
__ext.name = ${jsonEncode(meta.name)};
__ext.webSite = ${jsonEncode(meta.webSite)};
'ok'
''');
    if (instResult.isError) {
      throw ExtensionException(meta.package, 'instantiation failed: ${instResult.stringResult}');
    }

    await _call('load', []);
  }

  void dispose() {
    _generation++;
    _ready = false;
    _initializing = null;
    try {
      _rt?.dispose();
    } catch (_) {}
    _rt = null;
  }

  // ---------- public API ----------

  Future<List<MediaItem>> latest(int page, {String? channel}) async {
    final res = await _call('latest', [page, channel]);
    return _toItems(res);
  }

  /// Browse channels the source offers (categories, rankings, sort orders).
  Future<List<MediaChannel>> channels() async {
    try {
      final res = await _call('channels', []);
      if (res is! List) return const [];
      return res
          .whereType<Map>()
          .map((m) => MediaChannel(
                title: (m['title'] ?? '').toString(),
                key: (m['key'] ?? '').toString(),
              ))
          .where((c) => c.title.isNotEmpty)
          .toList();
    } catch (e) {
      // A source without working channels should still be browsable.
      debugPrint('[ext:${meta.package}] channels() failed: $e');
      return const [];
    }
  }

  Future<List<MediaItem>> search(String kw, int page) async {
    final res = await _call('search', [kw, page, <String, dynamic>{}]);
    return _toItems(res);
  }

  Future<MediaDetail> detail(String url, {String? title}) async {
    final res = await _call('detail', [url, {'title': title}]);
    if (res is! Map) throw ExtensionException(meta.package, 'detail() returned ${res.runtimeType}');
    return MediaDetail.fromJson(res);
  }

  Future<List<MediaItem>> searchAuthor(MediaAuthor author, int page) async {
    return _toItems(await _call('searchAuthor', [author.toJson(), page]));
  }

  Future<CommentPage> comments(String workUrl, String chapterUrl, int page,
      {String? parentId}) async {
    final res = await _call('comments', [workUrl, chapterUrl, page, parentId]);
    if (res is! Map || res['comments'] is! List) {
      throw ExtensionException(meta.package, '评论返回格式不正确，请稍后重试');
    }
    return CommentPage.fromJson(res);
  }

  /// Raw watch result — callers pick the typed wrapper based on [meta.type].
  Future<Map> watch(String url, {String? title}) async {
    final res = await _call('watch', [url, {'title': title}]);
    if (res is! Map) throw ExtensionException(meta.package, 'watch() returned ${res.runtimeType}');
    return res;
  }

  Future<List<DanmakuComment>> danmaku(String url, double from, double to) async {
    final res = await _call('danmaku', [url, from, to]);
    return parseDanmaku(res, 'dplayer');
  }

  List<MediaItem> _toItems(dynamic res) {
    if (res is! List) return const [];
    return res
        .whereType<Map>()
        .map((m) => MediaItem.fromExtension(m, meta))
        .where((m) => m.url.isNotEmpty)
        .toList();
  }

  // ---------- JS invocation ----------

  Future<dynamic> _call(String method, List<dynamic> args) async {
    final rt = _rt;
    if (rt == null) throw ExtensionException(meta.package, 'runtime not initialized');
    final expr = '__invoke(${jsonEncode(method)}, ${jsonEncode(jsonEncode(args))})';
    // Browser-rendered chapters may have many sequential sub-pages.
    final timeout = meta.package == 'linovelib' && method == 'watch'
        ? const Duration(minutes: 5)
        : const Duration(seconds: 120);
    final String raw;
    if (rt is AppleJsRuntime) {
      try {
        raw = await rt.invoke(expr, timeout: timeout);
      } catch (error) {
        throw ExtensionException(meta.package, '$method() $error');
      }
    } else {
      final promise = await rt.evaluateAsync(expr);
      rt.executePendingJob();
      final settled = await rt.handlePromise(promise, timeout: timeout);
      raw = settled.stringResult;
    }
    return decodeExtensionResult(raw,
        package: meta.package, method: method);
  }

  // ---------- bridge plumbing ----------

  void _channel(JavascriptRuntime rt, String name, Future<dynamic> Function(dynamic payload) handler) {
    rt.onMessage(name, (dynamic args) {
      final id = args['id'];
      final payload = args['payload'];
      Future(() async {
        bool ok;
        dynamic data;
        try {
          data = await handler(payload);
          ok = true;
        } catch (e) {
          ok = false;
          data = e.toString();
        }
        _resolveBridge(rt, id, ok, data);
      });
      return null;
    });
  }

  void _resolveBridge(JavascriptRuntime rt, dynamic id, bool ok, dynamic data) {
    if (!identical(rt, _rt)) return;
    // Double-encode: the inner JSON is passed as a string literal to JS.
    final literal = jsonEncode(jsonEncode(data));
    try {
      rt.evaluate('__resolveBridge($id, $ok, $literal)');
      rt.executePendingJob();
    } catch (e) {
      debugPrint('[ext:${meta.package}] bridge resolve failed: $e');
    }
  }

  // ---------- bridge handlers ----------

  Future<dynamic> _handleRequest(dynamic payload) async {
    final url = payload['url'].toString();
    final options = payload['options'] as Map? ?? {};
    final method = (options['method'] ?? 'get').toString().toUpperCase();
    final headers = <String, String>{};
    (options['headers'] as Map? ?? {}).forEach((k, v) => headers[k.toString()] = v.toString());
    headers.putIfAbsent('User-Agent', () => kDefaultUserAgent);

    final override = options['netMode']?.toString();
    if (options['browser'] == true) {
      if (meta.package != 'linovelib' || method != 'GET') {
        throw ExtensionException(meta.package, '浏览器加载仅用于哔哩轻小说的章节页面');
      }
      return BrowserLoader.load(
        url: url,
        headers: headers,
        selector: (options['browserSelector'] ?? '#acontent').toString(),
        rejectPattern: (options['browserRejectPattern'] ?? '').toString(),
        proxy: Network.usesProxyFor(meta.package, override: override)
            ? Network.resolvedProxy()
            : '',
      );
    }
    final dio = override == null
        ? Network.forPackage(meta.package)
        : (override == 'direct' ? Network.direct : Network.proxied);

    // Some APIs report errors as 4xx with a JSON body; those extensions opt in
    // to receiving the body instead of an exception.
    final allowErrorStatus = options['allowErrorStatus'] == true;
    final timeoutMs = (options['timeoutMs'] as num?)?.toInt().clamp(1000, 120000);

    // Source sites throw transient 5xx and connection resets often enough that
    // a single failure would wrongly mark a working source as broken.
    Response response;
    var attempt = 0;
    while (true) {
      final cancel = timeoutMs == null ? null : CancelToken();
      final timer = timeoutMs == null ? null : Timer(
        Duration(milliseconds: timeoutMs),
        () => cancel!.cancel('请求超时'),
      );
      try {
        response = await dio.request(
          url,
          data: options['data'],
          options: Options(
            method: method,
            headers: headers,
            responseType: ResponseType.plain,
            receiveTimeout: timeoutMs == null ? null : Duration(milliseconds: timeoutMs),
            sendTimeout: timeoutMs == null ? null : Duration(milliseconds: timeoutMs),
            validateStatus: allowErrorStatus
                ? (s) => s != null && s < 600
                : (s) => s != null && s < 400,
          ),
          cancelToken: cancel,
        );
        break;
      } on DioException catch (e) {
        final status = e.response?.statusCode ?? 0;
        // 429 means we asked too fast, so back off much harder than for a
        // flaky 5xx and honour Retry-After when the server sends one.
        final rateLimited = status == 429;
        final retryable = rateLimited ||
            status >= 500 ||
            e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.receiveTimeout ||
            e.type == DioExceptionType.connectionError;
        final maxAttempts = rateLimited ? 4 : 2;
        if (options['retry'] != false && retryable && attempt < maxAttempts) {
          attempt++;
          var wait = Duration(milliseconds: 600 * attempt);
          if (rateLimited) {
            final retryAfter =
                int.tryParse(e.response?.headers.value('retry-after') ?? '');
            wait = retryAfter != null
                ? Duration(seconds: retryAfter.clamp(1, 60))
                : Duration(seconds: 2 << attempt); // 4s, 8s, 16s, 32s
          }
          await Future.delayed(wait);
          continue;
        }
        // Surface what the server actually said — a bare status code hides the
        // API's own error payload, which is usually the real diagnosis.
        final body = e.response?.data?.toString() ?? '';
        if (body.isEmpty) rethrow;
        throw ExtensionException(
          meta.package,
          'HTTP $status: ${body.substring(0, body.length.clamp(0, 400))}',
        );
      } finally {
        timer?.cancel();
      }
    }
    final text = response.data.toString();
    final contentType = response.headers.value('content-type') ?? '';
    if (contentType.contains('json')) {
      try {
        return jsonDecode(text);
      } catch (_) {}
    }
    return text;
  }

  Future<dynamic> _handleQuerySelector(dynamic payload) async {
    final doc = html_parser.parse(payload['content'].toString());
    final el = doc.querySelector(payload['selector'].toString());
    if (el == null) return null;
    return {
      'text': el.text,
      'content': el.outerHtml,
      'attributes': el.attributes.map((k, v) => MapEntry(k.toString(), v)),
    };
  }

  Future<dynamic> _handleQuerySelectorAll(dynamic payload) async {
    final doc = html_parser.parse(payload['content'].toString());
    final els = doc.querySelectorAll(payload['selector'].toString());
    return els
        .map((el) => {
              'text': el.text,
              'content': el.outerHtml,
              'attributes': el.attributes.map((k, v) => MapEntry(k.toString(), v)),
            })
        .toList();
  }

  Future<dynamic> _handleGetAttributeText(dynamic payload) async {
    final doc = html_parser.parse(payload['content'].toString());
    final el = doc.querySelector(payload['selector'].toString());
    return el?.attributes[payload['attr'].toString()];
  }

  Future<dynamic> _handleQueryXPath(dynamic payload) async {
    try {
      final result = HtmlXPath.html(payload['content'].toString())
          .queryXPath(payload['expression'].toString());
      final allText = <String>[];
      final allHtml = <String>[];
      if (result.attrs.isNotEmpty) {
        allText.addAll(result.attrs.whereType<String>());
      }
      for (final node in result.nodes) {
        try {
          allText.add(node.text ?? '');
        } catch (_) {}
        try {
          allHtml.add(node.node.toString());
        } catch (_) {}
      }
      return {
        'text': allText.isNotEmpty ? allText.first : '',
        'html': allHtml.isNotEmpty ? allHtml.first : '',
        'allText': allText,
        'allHtml': allHtml,
      };
    } catch (e) {
      return {'text': '', 'html': '', 'allText': [], 'allHtml': []};
    }
  }

  Future<dynamic> _handleSleep(dynamic payload) async {
    final ms = (payload['ms'] as num?)?.toInt() ?? 0;
    await Future.delayed(Duration(milliseconds: ms.clamp(0, 10000)));
    return null;
  }

  Future<dynamic> _handleMd5(dynamic payload) async =>
      md5.convert(utf8.encode(payload['text'].toString())).toString();

  Future<dynamic> _handleHmacSha256(dynamic payload) async {
    final hmac = Hmac(sha256, utf8.encode(payload['key'].toString()));
    return hmac.convert(utf8.encode(payload['data'].toString())).toString();
  }

  Future<dynamic> _handleBase64Encode(dynamic payload) async =>
      base64Encode(utf8.encode(payload['text'].toString()));

  Future<dynamic> _handleAesEcbDecrypt(dynamic payload) async =>
      decryptAesEcb(payload['ciphertext'].toString(), payload['key'].toString());

  Future<dynamic> _handleRegisterSetting(dynamic payload) async {
    final setting = payload['setting'] as Map? ?? {};
    final key = setting['key']?.toString();
    if (key == null) return null;
    // Only store the default the first time; user values persist.
    if (Storage.extSetting(meta.package, key) == null) {
      await Storage.setExtSetting(meta.package, key, setting['defaultValue']);
    }
    // Keep the declaration so the settings UI knows what to render.
    await Storage.putExtSettingSchema(meta.package, {
      'key': key,
      'title': (setting['title'] ?? key).toString(),
      'type': (setting['type'] ?? 'input').toString(),
      'description': (setting['description'] ?? '').toString(),
      'defaultValue': setting['defaultValue'],
    });
    return null;
  }

  Future<dynamic> _handleGetSetting(dynamic payload) async =>
      Storage.extSetting(meta.package, payload['key'].toString());

  Future<dynamic> _handleSetSetting(dynamic payload) async {
    await Storage.setExtSetting(meta.package, payload['key'].toString(), payload['value']);
    return null;
  }
}
