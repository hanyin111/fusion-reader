import 'dart:math' as math;
import 'dart:ui';

import '../models/danmaku.dart';

class DanmakuPlacement {
  final DanmakuComment comment;
  final Size size;
  final int lane;
  final double viewportWidth;
  final double duration;

  const DanmakuPlacement(
    this.comment,
    this.size,
    this.lane,
    this.viewportWidth,
    this.duration,
  );

  double get end => comment.time + duration;
  double get speed => (viewportWidth + size.width) / duration;
  double xAt(double time) => comment.mode == DanmakuMode.scroll
      ? viewportWidth - (time - comment.time) * speed
      : (viewportWidth - size.width) / 2;
}

/// Advance using video seconds, never wall time. Rebuild on backward/large
/// seeks; pause and playback speed therefore need no special scheduling.
class DanmakuTimeline {
  static const scrollDuration = 8.0;
  static const fixedDuration = 4.0;
  final List<DanmakuComment> comments;
  final Size Function(DanmakuComment) measure;
  final List<DanmakuPlacement> _active = [];
  int _next = 0;
  double _lastTime = -1;
  double _width = 0;
  int _lanes = 0;

  DanmakuTimeline(this.comments, this.measure);

  void reset() {
    _active.clear();
    _next = 0;
    _lastTime = -1;
  }

  int _lowerBound(double time) {
    var low = 0, high = comments.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (comments[mid].time < time) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  List<DanmakuPlacement> at(
    double time, {
    required double width,
    required int lanes,
  }) {
    if (!time.isFinite || time < 0 || width <= 0 || lanes <= 0) return const [];
    if (_lastTime < 0 ||
        time < _lastTime ||
        time - _lastTime > 1.0 ||
        width != _width ||
        lanes != _lanes) {
      reset();
      // One extra lifetime keeps lane assignments stable while rebuilding.
      _next = _lowerBound(math.max(0, time - scrollDuration * 2));
    }
    _width = width;
    _lanes = lanes;
    while (_next < comments.length && comments[_next].time <= time) {
      final comment = comments[_next++];
      _active.removeWhere((item) => item.end <= comment.time);
      final size = measure(comment);
      final duration = comment.mode == DanmakuMode.scroll
          ? scrollDuration
          : fixedDuration;
      final availableLanes = comment.mode == DanmakuMode.bottom
          ? math.min(2, lanes)
          : lanes;
      for (var lane = 0; lane < availableLanes; lane++) {
        final candidate = DanmakuPlacement(
          comment,
          size,
          lane,
          width,
          duration,
        );
        final overlaps = _active.any((previous) {
          if (previous.lane != lane) return false;
          // Top and bottom have independent physical lanes. Scrolling uses
          // the top half, so reserve lanes occupied by fixed top comments.
          if (previous.comment.mode == DanmakuMode.bottom ||
              comment.mode == DanmakuMode.bottom) {
            return previous.comment.mode == comment.mode;
          }
          if (previous.comment.mode != DanmakuMode.scroll ||
              comment.mode != DanmakuMode.scroll) {
            return true;
          }
          final gap = width - previous.xAt(comment.time) - previous.size.width;
          if (gap < 16) return true;
          // A wider (faster) trailing comment must not catch its predecessor.
          final catchUp = candidate.speed - previous.speed;
          return catchUp > 0 &&
              gap - catchUp * (previous.end - comment.time) < 16;
        });
        if (!overlaps) {
          _active.add(candidate);
          break;
        }
      }
    }
    _active.removeWhere((item) => item.end <= time);
    _lastTime = time;
    return List.unmodifiable(_active);
  }
}
