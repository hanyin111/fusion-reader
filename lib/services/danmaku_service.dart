import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/danmaku.dart';
import 'network.dart';

class DanmakuService {
  static Future<List<DanmakuComment>> load(
    String package,
    DanmakuSource source, {
    CancelToken? cancelToken,
  }) async {
    final client = Network.forPackage(package, override: source.netMode);
    var received = 0;
    final token = cancelToken ?? CancelToken();
    final response = await client
        .get<List<int>>(
          source.url,
          cancelToken: token,
          options: Options(
            responseType: ResponseType.bytes,
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
    return parseDanmaku(
      decodeDanmakuBytes(
        response.data ?? [],
        source.format,
        encoding: response.headers.value('content-encoding') ?? '',
      ),
      source.format,
    );
  }
}

String decodeDanmakuBytes(
  List<int> bytes,
  String format, {
  String encoding = '',
  int limit = 8 * 1024 * 1024,
}) {
  if (bytes.length > limit) throw const FormatException('弹幕数据过大');
  final prefix = bytes
      .skipWhile((byte) => const [9, 10, 13, 32].contains(byte))
      .take(3)
      .toList();
  final plain =
      prefix.isEmpty ||
      prefix.first == 0x3c ||
      prefix.first == 0x7b ||
      prefix.first == 0x5b ||
      (prefix.length >= 3 &&
          prefix[0] == 0xef &&
          prefix[1] == 0xbb &&
          prefix[2] == 0xbf);
  if (plain) return utf8.decode(bytes);
  Uint8List inflate(Converter<List<int>, List<int>> decoder) {
    final sink = _LimitedDanmakuBytes(limit);
    final input = decoder.startChunkedConversion(sink);
    input.add(bytes);
    input.close();
    return sink.builder.takeBytes();
  }

  if (prefix.length >= 2 && prefix[0] == 0x1f && prefix[1] == 0x8b) {
    return utf8.decode(inflate(gzip.decoder));
  }
  if (format == 'bilibili' || encoding.toLowerCase().contains('deflate')) {
    try {
      return utf8.decode(inflate(ZLibDecoder()));
    } catch (error) {
      if (error is FormatException && error.message == '弹幕数据过大') rethrow;
      return utf8.decode(inflate(ZLibDecoder(raw: true)));
    }
  }
  return utf8.decode(bytes);
}

class _LimitedDanmakuBytes implements Sink<List<int>> {
  final int limit;
  final builder = BytesBuilder(copy: false);
  _LimitedDanmakuBytes(this.limit);
  @override
  void add(List<int> data) {
    if (builder.length + data.length > limit) {
      throw const FormatException('弹幕数据过大');
    }
    builder.add(data);
  }

  @override
  void close() {}
}
