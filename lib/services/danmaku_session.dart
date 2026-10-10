import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';

import '../models/danmaku.dart';

typedef DanmakuWindowLoader =
    Future<List<DanmakuComment>> Function(
      double from,
      double to,
      CancelToken token,
    );

/// Fetch short windows on demand, including seeks, without polling the server.
class DanmakuSession {
  final int windowSeconds;
  final DanmakuWindowLoader load;
  final void Function(List<DanmakuComment>, bool, String?) onChanged;
  final _windows = <({double from, double to, List<DanmakuComment> rows})>[];
  CancelToken? _request;
  bool _disposed = false;
  double _position = 0;
  DateTime? _retryAfter;

  DanmakuSession({
    required this.load,
    required this.onChanged,
    this.windowSeconds = 180,
  });

  List<DanmakuComment> get comments {
    final merged = <String, DanmakuComment>{};
    for (final window in _windows) {
      for (final row in window.rows) {
        merged['${row.time}|${row.text}|${row.color}|${row.mode}'] = row;
      }
    }
    return merged.values.toList()..sort((a, b) => a.time.compareTo(b.time));
  }

  Future<void> update(double position, {bool force = false}) async {
    if (_disposed || !position.isFinite || position < 0) return;
    _position = position;
    if (_request != null) return;
    if (!force &&
        (_windows.any((w) => position >= w.from && position + 30 < w.to) ||
            (_retryAfter?.isAfter(DateTime.now()) ?? false))) {
      return;
    }
    final token = _request = CancelToken();
    final from = max(0.0, position - 15);
    final to = from + windowSeconds;
    onChanged(comments, true, null);
    try {
      final rows = await load(from, to, token);
      if (_disposed || token.isCancelled) return;
      _windows.removeWhere((w) => w.from >= from && w.to <= to);
      _windows.add((from: from, to: to, rows: rows.take(4000).toList()));
      if (_windows.length > 12) _windows.removeAt(0);
      _retryAfter = null;
      final all = comments;
      onChanged(all, false, all.isEmpty ? '当前播放范围暂时没有弹幕' : null);
    } catch (_) {
      if (_disposed || token.isCancelled) return;
      _retryAfter = DateTime.now().add(const Duration(seconds: 30));
      onChanged(comments, false, '弹幕加载失败，可重试；视频仍可正常播放');
    } finally {
      if (identical(_request, token)) _request = null;
    }
    // A seek during loading must fetch the new position as soon as it settles.
    if (!_disposed && (_position < from || _position + 30 >= to)) {
      unawaited(update(_position));
    }
  }

  void dispose() {
    _disposed = true;
    _request?.cancel();
    _windows.clear();
  }
}
