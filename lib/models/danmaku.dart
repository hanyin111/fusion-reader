import 'dart:convert';

import 'package:xml/xml.dart';

enum DanmakuMode { scroll, top, bottom }

class DanmakuComment {
  final double time;
  final String text;
  final int color;
  final DanmakuMode mode;

  const DanmakuComment({
    required this.time,
    required this.text,
    this.color = 0xffffff,
    this.mode = DanmakuMode.scroll,
  });
}

/// A plugin supplies an endpoint; the player owns parsing and rendering.
/// This optional watch() field is ignored by older clients.
class DanmakuSource {
  final String url;
  final String format;
  final Map<String, String> headers;
  final String? netMode;

  const DanmakuSource({
    required this.url,
    this.format = 'dplayer',
    this.headers = const {},
    this.netMode,
  });

  static DanmakuSource? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final url = (raw['url'] ?? '').toString();
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      return null;
    }
    return DanmakuSource(
      url: url,
      format: (raw['format'] ?? 'dplayer').toString(),
      headers: raw['headers'] is Map
          ? (raw['headers'] as Map).map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            )
          : const {},
      netMode: raw['netMode']?.toString(),
    );
  }
}

/// DPlayer: [seconds, mode (0/1/2), RGB, author, text].
/// Bilibili XML: `<d p="seconds,mode,size,RGB,...">text</d>`.
/// Limit both the response and individual comments before painting.
List<DanmakuComment> parseDanmaku(dynamic response, String format) {
  final comments = <DanmakuComment>[];
  void add(dynamic time, dynamic text, dynamic color, DanmakuMode? mode) {
    final seconds = double.tryParse(time.toString());
    if (seconds == null || !seconds.isFinite || seconds < 0 || mode == null) {
      return;
    }
    var content = (text ?? '')
        .toString()
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
        .trim();
    if (content.isEmpty) return;
    if (content.runes.length > 120) {
      content = String.fromCharCodes(content.runes.take(120));
    }
    final rgb = int.tryParse(color.toString()) ?? 0xffffff;
    comments.add(
      DanmakuComment(
        time: seconds,
        text: content,
        color: rgb & 0xffffff,
        mode: mode,
      ),
    );
  }

  if (format == 'bilibili') {
    final xml = XmlDocument.parse(response.toString());
    for (final node in xml.findAllElements('d').take(50000)) {
      final p = (node.getAttribute('p') ?? '').split(',');
      if (p.length < 4) continue;
      final mode = switch (p[1]) {
        '1' || '2' || '3' => DanmakuMode.scroll,
        '4' => DanmakuMode.bottom,
        '5' => DanmakuMode.top,
        _ => null,
      };
      add(p[0], node.innerText, p[3], mode);
    }
  } else if (format == 'dplayer') {
    final decoded = response is String ? jsonDecode(response) : response;
    if (decoded is Map && decoded['code'] != null && decoded['code'] != 0) {
      throw const FormatException('弹幕接口返回错误');
    }
    final rows = decoded is Map ? decoded['data'] : decoded;
    if (rows is! List) throw const FormatException('弹幕数据格式不正确');
    for (final row in rows.take(50000)) {
      if (row is! List || row.length < 5) continue;
      final mode = switch (row[1].toString()) {
        '0' => DanmakuMode.scroll,
        '1' => DanmakuMode.top,
        '2' => DanmakuMode.bottom,
        _ => null,
      };
      add(row[0], row[4], row[2], mode);
    }
  } else {
    throw const FormatException('暂不支持此弹幕格式');
  }
  comments.sort((a, b) => a.time.compareTo(b.time));
  return comments;
}
