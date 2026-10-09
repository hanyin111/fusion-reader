import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// URL fragments carry the page context, without sending it to the CDN or
/// changing the extension watch() schema. Covers have no page context.
class SourceImageCodec {
  static int _active = 0;
  static final Queue<Completer<void>> _waiting = Queue();
  static const jmUserAgent =
      'Mozilla/5.0 (Linux; Android 10; K; wv) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Version/4.0 Chrome/130.0.0.0 Mobile Safari/537.36';

  static Map<String, String> headersFor(
    String package,
    Map<String, String>? headers,
  ) => {
    if (package == 'jmcomic') ...{
      'User-Agent': jmUserAgent,
      'Referer': 'https://localhost/',
      'X-Requested-With': 'com.example.app',
    },
    ...?headers,
  };

  static int? episodeId(String package, String url) {
    if (package != 'jmcomic') return null;
    final uri = Uri.tryParse(url);
    if (uri == null || !['http', 'https'].contains(uri.scheme)) return null;
    final match = RegExp(r'^fusion-jmcomic=(\d+)$').firstMatch(uri.fragment);
    final id = match == null ? null : int.tryParse(match[1]!);
    // A marker must agree with the path so unrelated images cannot be altered.
    final path = uri.pathSegments;
    if (id == null ||
        path.length < 4 ||
        path[path.length - 4] != 'media' ||
        path[path.length - 3] != 'photos' ||
        path[path.length - 2] != '$id') {
      return null;
    }
    return id;
  }

  static String requestUrl(String package, String url) =>
      episodeId(package, url) == null
      ? url
      : Uri.parse(url).removeFragment().toString();

  static int sliceCount(int episode, String filename) {
    if (filename.toLowerCase().endsWith('.gif') || episode < 220980) return 0;
    if (episode < 268850) return 10;
    final dot = filename.lastIndexOf('.');
    final name = dot < 0 ? filename : filename.substring(0, dot);
    final hex = md5.convert(utf8.encode('$episode$name')).toString();
    // The protocol uses the ASCII code of the last hex character, not its
    // numeric hex value. The threshold comparison is strictly greater-than.
    return (hex.codeUnitAt(hex.length - 1) % (episode > 421926 ? 8 : 10)) * 2 +
        2;
  }

  static Future<Uint8List> decode(
    String package,
    String url,
    Uint8List bytes,
  ) async {
    final episode = episodeId(package, url);
    if (episode == null) return bytes;
    final filename = Uri.parse(url).pathSegments.last;
    final count = sliceCount(episode, filename);
    if (count < 2) return bytes;
    // Bound uncompressed buffers when a long comic list requests many pages.
    if (_active < 2) {
      _active++;
    } else {
      final waiting = Completer<void>();
      _waiting.add(waiting);
      await waiting.future;
    }
    try {
      return await compute(_restoreJmImage, (bytes, count));
    } finally {
      if (_waiting.isEmpty) {
        _active--;
      } else {
        _waiting.removeFirst().complete();
      }
    }
  }
}

/// Aidoku Community zh.jmcomic, MIT; see the bundled license notice.
/// In the scrambled image the last stripe also contains the remainder rows.
Uint8List _restoreJmImage((Uint8List, int) input) {
  final (bytes, count) = input;
  final img.Image? source;
  try {
    source = img.decodeImage(bytes);
  } catch (_) {
    throw const FormatException('图片响应不是有效的图片');
  }
  if (source == null) throw const FormatException('图片响应不是有效的图片');
  if (source.height < count) throw const FormatException('图片高度不足，无法还原');
  final result = img.Image(
    width: source.width,
    height: source.height,
    numChannels: source.numChannels,
  );
  final stripe = source.height ~/ count;
  final remainder = source.height % count;
  var destination = 0;
  for (var index = count - 1; index >= 0; index--) {
    final height = stripe + (index == count - 1 ? remainder : 0);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < source.width; x++) {
        result.setPixel(
          x,
          destination + y,
          source.getPixel(x, index * stripe + y),
        );
      }
    }
    destination += height;
  }
  // Lossless encoding avoids degrading text with a second JPEG compression.
  return img.encodePng(result, level: 1);
}
