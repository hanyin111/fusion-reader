import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

/// Renders dynamic chapter pages before handing their HTML to an extension.
/// Each page has a bounded lifetime; browser cookies survive between pages.
class BrowserLoader {
  static const _hosts = {
    'www.linovelib.com',
    'tw.linovelib.com',
    'm.bilinovel.com',
    'www.bilinovel.com',
    'www.bilinovel.net',
  };
  static final Map<String, Future<WebViewEnvironment>> _environments = {};
  static final Map<String, DateTime> _sessions = {};
  static Future<void> _queue = Future.value();

  static Future<String> load({
    required String url,
    required Map<String, String> headers,
    required String selector,
    required String rejectPattern,
    required String proxy,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final uri = Uri.tryParse(url);
    if (uri?.scheme != 'https' || !_hosts.contains(uri?.host)) {
      throw ArgumentError('浏览器正文加载只接受哔哩轻小说的 HTTPS 地址');
    }
    if (!(Platform.isWindows ||
        Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS)) {
      throw UnsupportedError('此设备暂不支持浏览器正文加载，请使用 Windows、Android、iOS 或 macOS。');
    }
    final previous = _queue;
    final done = Completer<void>();
    _queue = done.future;
    ProxyController? androidProxy;
    try {
      await previous;
      if (Platform.isAndroid &&
          await WebViewFeature.isFeatureSupported(
            WebViewFeature.PROXY_OVERRIDE,
          )) {
        androidProxy = ProxyController.instance();
        await androidProxy.setProxyOverride(
          settings: ProxySettings(
            proxyRules: proxy.isEmpty ? [] : [ProxyRule(url: 'http://$proxy')],
            directs: proxy.isEmpty ? ['*'] : [],
          ),
        );
      } else if (!Platform.isWindows && proxy.isNotEmpty) {
        throw UnsupportedError('此设备的浏览器不支持代理覆盖，请使用系统网络。');
      }
      return await _load(url, headers, selector, rejectPattern, proxy, timeout);
    } finally {
      try {
        await androidProxy?.clearProxyOverride();
      } finally {
        done.complete();
      }
    }
  }

  static Future<WebViewEnvironment?> _environment(String proxy) async {
    if (!Platform.isWindows) return null;
    if (await WebViewEnvironment.getAvailableVersion() == null) {
      throw StateError('加载完整章节需要 Microsoft Edge WebView2，请先安装 WebView2 运行时。');
    }
    final key = sha256.convert(utf8.encode(proxy)).toString().substring(0, 16);
    final environment = _environments.putIfAbsent(key, () async {
      final support = await getApplicationSupportDirectory();
      final profile = Directory('${support.path}/browser/linovelib/$key');
      await profile.create(recursive: true);
      return WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(
          userDataFolder: profile.path,
          language: 'zh-CN',
          additionalBrowserArguments: proxy.isEmpty
              ? '--no-proxy-server'
              : '--proxy-server=http://$proxy',
        ),
      );
    });
    try {
      return await environment;
    } catch (_) {
      _environments.remove(key);
      rethrow;
    }
  }

  static Future<String> _load(
    String url,
    Map<String, String> headers,
    String selector,
    String rejectPattern,
    String proxy,
    Duration timeout,
  ) async {
    final clock = Stopwatch()..start();
    Duration remaining() {
      final remaining = timeout - clock.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('站点仍未加载完整正文，请稍后重试或检查此源的网络设置。', timeout);
      }
      return remaining;
    }

    final environment = await _environment(proxy).timeout(remaining());
    final sessionKey = '${Uri.parse(url).host}|$proxy';
    InAppWebViewController? controller;
    final created = Completer<InAppWebViewController>();
    String? loadError;
    String? lastContent;
    String? reportedReason;
    var stable = 0;
    final view = HeadlessInAppWebView(
      initialSize: const Size(390, 844),
      webViewEnvironment: environment,
      initialSettings: InAppWebViewSettings(
        userAgent: headers['User-Agent'],
        javaScriptEnabled: true,
        preferredContentMode: UserPreferredContentMode.MOBILE,
        useShouldOverrideUrlLoading: true,
      ),
      initialUserScripts: UnmodifiableListView([
        UserScript(
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: true,
          source: '''
// Keep the JS device identity consistent with the mobile HTTP User-Agent.
Object.defineProperty(navigator, 'platform', {get: () => 'Linux armv81'});
Object.defineProperty(navigator, 'language', {get: () => 'zh-CN'});
Object.defineProperty(navigator, 'languages', {get: () => ['zh-CN', 'zh']});
''',
        ),
      ]),
      onWebViewCreated: (value) {
        controller = value;
        created.complete(value);
      },
      shouldOverrideUrlLoading: (_, action) async {
        final destination = action.request.url;
        if (action.isForMainFrame == true &&
            destination != null &&
            destination.toString() != 'about:blank' &&
            (destination.scheme != 'https' ||
                !_hosts.contains(destination.host))) {
          return NavigationActionPolicy.CANCEL;
        }
        return NavigationActionPolicy.ALLOW;
      },
      onReceivedError: (_, request, error) {
        // Moving from the catalogue to the chapter cancels outstanding loads.
        if (request.isForMainFrame == true &&
            error.type != WebResourceErrorType.CANCELLED) {
          loadError = error.description;
        }
      },
      onReceivedHttpError: (_, request, response) {
        if (request.isForMainFrame == true &&
            (response.statusCode ?? 0) >= 400) {
          loadError = 'HTTP ${response.statusCode}';
        }
      },
      onCreateWindow: (_, _) async => false,
    );

    try {
      await view.run().timeout(remaining());
      final browser = await created.future.timeout(remaining());
      if (Platform.isWindows) {
        final agent = headers['User-Agent']!;
        final version =
            RegExp(r'Chrome/([\d.]+)').firstMatch(agent)?.group(1) ??
            '131.0.0.0';
        final major = version.split('.').first;
        // WebView2 otherwise sends Windows/desktop Client Hints even with a mobile UA.
        await browser
            .callDevToolsProtocolMethod(
              methodName: 'Emulation.setUserAgentOverride',
              parameters: {
                'userAgent': agent,
                'acceptLanguage': 'zh-CN,zh',
                'platform': 'Linux armv81',
                'userAgentMetadata': {
                  'brands': [
                    {'brand': 'Chromium', 'version': major},
                    {'brand': 'Google Chrome', 'version': major},
                  ],
                  'fullVersionList': [
                    {'brand': 'Chromium', 'version': version},
                    {'brand': 'Google Chrome', 'version': version},
                  ],
                  'platform': 'Android',
                  'platformVersion': '14.0.0',
                  'architecture': 'arm',
                  'bitness': '64',
                  'model': 'Pixel 8',
                  'mobile': true,
                },
              },
            )
            .timeout(remaining());
        await browser
            .callDevToolsProtocolMethod(
              methodName: 'Emulation.setDeviceMetricsOverride',
              parameters: {
                'width': 390,
                'height': 844,
                'deviceScaleFactor': 3,
                'mobile': true,
              },
            )
            .timeout(remaining());
        await browser
            .callDevToolsProtocolMethod(
              methodName: 'Emulation.setTouchEmulationEnabled',
              parameters: {'enabled': true, 'maxTouchPoints': 5},
            )
            .timeout(remaining());
      }
      // The catalogue runs the site's session scripts. Dio's cookie jar is
      // separate from the browser profile, so a mobile UA alone cannot do this.
      final book = RegExp(r'/novel/(\d+)/').firstMatch(Uri.parse(url).path);
      final lastSession = _sessions[sessionKey];
      if (book != null &&
          (lastSession == null ||
              DateTime.now().difference(lastSession) >
                  const Duration(minutes: 10))) {
        final catalog = Uri.parse(
          url,
        ).resolve('/novel/${book.group(1)}/catalog');
        await browser
            .loadUrl(
              urlRequest: URLRequest(
                url: WebUri(catalog.toString()),
                headers: headers,
              ),
            )
            .timeout(remaining());
        final started = clock.elapsed;
        var sessionReady = false;
        while (clock.elapsed < timeout) {
          if (loadError != null) throw StateError('目录加载失败：$loadError');
          sessionReady =
              await browser
                  .evaluateJavascript(
                    source:
                        '''
location.pathname === ${jsonEncode(catalog.path)} && document.readyState === 'complete' &&
document.cookie.split(';').some(cookie => cookie.trim().startsWith('jieqiSearchJs='))
''',
                  )
                  .timeout(remaining()) ==
              true;
          if (sessionReady &&
              clock.elapsed - started >= const Duration(seconds: 2)) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        if (!sessionReady) throw TimeoutException('站点未能建立阅读会话，请稍后重试。', timeout);
      }
      await browser
          .loadUrl(
            urlRequest: URLRequest(url: WebUri(url), headers: headers),
          )
          .timeout(remaining());
      while (clock.elapsed < timeout) {
        if (loadError != null) throw StateError('浏览器加载失败：$loadError');
        final current = controller;
        if (current != null) {
          dynamic snapshot;
          try {
            snapshot = await current
                .evaluateJavascript(
                  source: _snapshotScript(url, selector, rejectPattern),
                )
                .timeout(const Duration(seconds: 5));
          } on TimeoutException {
            // A script or navigation is still running. The overall deadline applies.
          }
          if (snapshot is Map && snapshot['ready'] == true) {
            final html = snapshot['html'] as String;
            final content = snapshot['content'] as String;
            if (content == lastContent) {
              stable++;
              if (stable >= 2) {
                _sessions[sessionKey] = DateTime.now();
                return html;
              }
            } else {
              lastContent = content;
              stable = 0;
            }
          } else {
            assert(() {
              final reason = snapshot?.toString();
              if (reason != reportedReason) {
                debugPrint('[browser:linovelib] $reason');
                reportedReason = reason;
              }
              return true;
            }());
            lastContent = null;
            stable = 0;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      throw TimeoutException('站点仍未加载完整正文，请稍后重试或检查此源的网络设置。', timeout);
    } catch (_) {
      _sessions.remove(sessionKey);
      rethrow;
    } finally {
      await view.dispose();
    }
  }

  static String _snapshotScript(
    String url,
    String selector,
    String rejectPattern,
  ) =>
      '''
(() => {
  const status = reason => ({ready: false, reason,
    url: location.href, title: document.title,
    platform: navigator.platform, mobile: navigator.userAgentData?.mobile,
    mobileUA: /Mobile/.test(navigator.userAgent)});
  const expected = new URL(${jsonEncode(url)});
  if (location.hostname !== expected.hostname || location.pathname !== expected.pathname) {
    return status('navigation');
  }
  const original = document.querySelector(${jsonEncode(selector)});
  if (!original || document.readyState === 'loading') return status('loading');
  function visibleClone(node) {
    if (node.nodeType === Node.TEXT_NODE) return node.cloneNode();
    if (node.nodeType !== Node.ELEMENT_NODE) return null;
    if (['SCRIPT', 'STYLE', 'IFRAME', 'INS', 'NOSCRIPT'].includes(node.tagName)) return null;
    const style = getComputedStyle(node);
    if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0' ||
        /^matrix\\(0, 0, 0, 0,/.test(style.transform)) return null;
    const clone = node.cloneNode(false);
    for (const child of node.childNodes) {
      const copy = visibleClone(child);
      if (copy) clone.appendChild(copy);
    }
    return clone;
  }
  const content = visibleClone(original);
  const reject = ${jsonEncode(rejectPattern)};
  if (!content || (reject && new RegExp(reject).test(content.textContent))) {
    return status('truncated');
  }
  if (!content.textContent.trim() && !content.querySelector('img')) return status('empty');
  const copy = document.documentElement.cloneNode(true);
  copy.querySelector(${jsonEncode(selector)}).replaceWith(content);
  return {ready: true, html: copy.outerHTML, content: content.outerHTML};
})()
''';
}
