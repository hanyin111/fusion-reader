import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:media_kit/media_kit.dart';

import '../models/danmaku.dart';
import '../services/danmaku_clock.dart';
import '../services/danmaku_timeline.dart';

class _RepaintSignal extends ChangeNotifier {
  void repaint() => notifyListeners();
}

class DanmakuDisplay {
  final List<DanmakuComment> comments;
  final bool enabled;
  final bool loading;
  final String? message;
  final double opacity;
  final double fontSize;
  final double area;

  const DanmakuDisplay({
    this.comments = const [],
    this.enabled = true,
    this.loading = false,
    this.message,
    this.opacity = .85,
    this.fontSize = 20,
    this.area = .5,
  });

  DanmakuDisplay copyWith({
    bool? enabled,
    double? opacity,
    double? fontSize,
    double? area,
  }) => DanmakuDisplay(
    comments: comments,
    enabled: enabled ?? this.enabled,
    loading: loading,
    message: message,
    opacity: opacity ?? this.opacity,
    fontSize: fontSize ?? this.fontSize,
    area: area ?? this.area,
  );
}

/// Mounted inside Video's controls builder so it also exists in fullscreen.
/// Text is laid out once and painted in its own repaint boundary. Pointer
/// events pass through to the player's original controls.
class DanmakuOverlay extends StatefulWidget {
  final Player player;
  final DanmakuDisplay display;
  const DanmakuOverlay({
    super.key,
    required this.player,
    required this.display,
  });

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay>
    with SingleTickerProviderStateMixin {
  final _repaint = _RepaintSignal();
  final _clock = Stopwatch()..start();
  final _subscriptions = <StreamSubscription>[];
  final _painters = <DanmakuComment, TextPainter>{};
  late final Ticker _ticker;
  late DanmakuTimeline _timeline;
  late final DanmakuClock _playbackClock;
  bool _playing = false, _buffering = false;

  double get _time => math.max(0, _playbackClock.time);

  @override
  void initState() {
    super.initState();
    final state = widget.player.state;
    _playbackClock = DanmakuClock(() => _clock.elapsedMicroseconds / 1000000)
      ..position(state.position.inMicroseconds / 1000000)
      ..playing(state.playing)
      ..buffering(state.buffering)
      ..rate(state.rate);
    _playing = state.playing;
    _buffering = state.buffering;
    _timeline = DanmakuTimeline(widget.display.comments, _measure);
    _ticker = createTicker((_) => _repaint.repaint());
    _subscriptions.addAll([
      widget.player.stream.position.listen((position) {
        final seconds = position.inMicroseconds / 1000000;
        _playbackClock.position(seconds);
        _repaint.repaint();
      }),
      widget.player.stream.playing.listen((playing) {
        _playbackClock.playing(playing);
        _playing = playing;
        _syncTicker();
      }),
      widget.player.stream.buffering.listen((buffering) {
        _playbackClock.buffering(buffering);
        _buffering = buffering;
        _syncTicker();
      }),
      widget.player.stream.rate.listen((rate) {
        _playbackClock.rate(rate);
      }),
    ]);
    _syncTicker();
  }

  void _syncTicker() {
    final shouldTick =
        widget.display.enabled &&
        widget.display.comments.isNotEmpty &&
        _playing &&
        !_buffering;
    if (shouldTick && !_ticker.isActive) _ticker.start();
    if (!shouldTick && _ticker.isActive) _ticker.stop();
    _repaint.repaint();
  }

  @override
  void didUpdateWidget(covariant DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.display.comments, widget.display.comments) ||
        oldWidget.display.fontSize != widget.display.fontSize) {
      _disposePainters();
      _timeline = DanmakuTimeline(widget.display.comments, _measure);
    } else if (oldWidget.display.opacity != widget.display.opacity) {
      _disposePainters();
    }
    if (oldWidget.display.enabled != widget.display.enabled) _timeline.reset();
    _syncTicker();
  }

  void _disposePainters() {
    for (final painter in _painters.values) {
      painter.dispose();
    }
    _painters.clear();
  }

  TextPainter _painter(DanmakuComment comment) {
    // Keep memory bounded when a long video contains tens of thousands of
    // comments. A seek can simply lay out discarded text again.
    if (_painters.length >= 800) _disposePainters();
    return _painters.putIfAbsent(
      comment,
      () => TextPainter(
        text: TextSpan(
          text: comment.text,
          style: TextStyle(
            fontSize: widget.display.fontSize,
            fontWeight: FontWeight.w600,
            color: Color(
              0xff000000 | comment.color,
            ).withValues(alpha: widget.display.opacity),
            shadows: [
              Shadow(
                color: Colors.black.withValues(alpha: widget.display.opacity),
                blurRadius: 2,
                offset: const Offset(1, 1),
              ),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(),
    );
  }

  Size _measure(DanmakuComment comment) => _painter(comment).size;

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _ticker.dispose();
    _clock.stop();
    _repaint.dispose();
    _disposePainters();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: RepaintBoundary(
        child: ClipRect(
          child: CustomPaint(
            painter: _DanmakuPainter(
              repaint: _repaint,
              time: () => _time,
              timeline: _timeline,
              display: widget.display,
              text: _painter,
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    ),
  );
}

class _DanmakuPainter extends CustomPainter {
  final double Function() time;
  final DanmakuTimeline timeline;
  final DanmakuDisplay display;
  final TextPainter Function(DanmakuComment) text;

  _DanmakuPainter({
    required Listenable repaint,
    required this.time,
    required this.timeline,
    required this.display,
    required this.text,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    if (!display.enabled || display.comments.isEmpty) return;
    final seconds = time();
    final lineHeight = display.fontSize * 1.5;
    // Keep bottom fixed comments and subtitles clear of scrolling tracks.
    final lanes = math.max(
      1,
      ((size.height - 88) * display.area / lineHeight).floor(),
    );
    for (final item in timeline.at(seconds, width: size.width, lanes: lanes)) {
      final y = item.comment.mode == DanmakuMode.bottom
          ? size.height - 64 - (item.lane + 1) * lineHeight
          : 12 + item.lane * lineHeight;
      text(
        item.comment,
      ).paint(canvas, Offset(item.xAt(seconds), math.max(0, y)));
    }
  }

  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) => true;
}
