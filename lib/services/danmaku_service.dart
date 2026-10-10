import 'dart:async';

import 'package:dio/dio.dart';

import '../models/danmaku.dart';
import 'network.dart';

class DanmakuService {
  static Future<List<DanmakuComment>> load(
    String package,
    DanmakuSource source, {
    CancelToken? cancelToken,
  }) async {
    final client = Network.usesProxyFor(package, override: source.netMode)
        ? Network.proxied
        : Network.direct;
    var received = 0;
    final token = cancelToken ?? CancelToken();
    final response = await client
        .get<String>(
          source.url,
          cancelToken: token,
          options: Options(
            responseType: ResponseType.plain,
            headers: source.headers,
            receiveTimeout: const Duration(seconds: 15),
            sendTimeout: const Duration(seconds: 15),
          ),
          onReceiveProgress: (count, total) {
            received = count;
            if (count > 8 * 1024 * 1024 || total > 8 * 1024 * 1024) {
              token.cancel('弹幕数据过大');
            }
          },
        )
        .timeout(
          const Duration(seconds: 25),
          onTimeout: () {
            token.cancel('弹幕加载超时');
            throw TimeoutException('弹幕加载超时');
          },
        );
    if (received > 8 * 1024 * 1024 ||
        (response.data?.length ?? 0) > 8 * 1024 * 1024) {
      throw const FormatException('弹幕数据过大');
    }
    return parseDanmaku(response.data ?? '', source.format);
  }
}
