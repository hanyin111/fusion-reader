import 'package:flutter/material.dart';

/// Keeps the scroll view's drag recognizer out of two-finger zoom gestures.
/// While magnified, one finger pans the image instead of changing pages.
class MangaZoomView extends StatefulWidget {
  final Widget Function(bool scrollingEnabled) builder;
  final ValueChanged<int> onZoomChanged;
  const MangaZoomView({
    super.key,
    required this.builder,
    required this.onZoomChanged,
  });

  @override
  State<MangaZoomView> createState() => MangaZoomViewState();
}

class MangaZoomViewState extends State<MangaZoomView> {
  final TransformationController _transform = TransformationController();
  final Set<int> _pointers = {};
  Size _viewport = Size.zero;
  Offset _doubleTapPosition = Offset.zero;
  int _percent = 100;
  bool get _zoomed => _transform.value.getMaxScaleOnAxis() > 1.001;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_changed);
  }

  @override
  void dispose() {
    _transform.removeListener(_changed);
    _transform.dispose();
    super.dispose();
  }

  void _changed() {
    final percent = (_transform.value.getMaxScaleOnAxis() * 100).round();
    if (percent == _percent) return;
    setState(() => _percent = percent);
    widget.onZoomChanged(percent);
  }

  void _pointer(int pointer, bool down) => setState(() {
    if (down) {
      _pointers.add(pointer);
    } else {
      _pointers.remove(pointer);
    }
  });

  void reset() => _transform.value = Matrix4.identity();
  void zoomIn() => _zoom(_transform.value.getMaxScaleOnAxis() * 1.5);
  void zoomOut() => _zoom(_transform.value.getMaxScaleOnAxis() / 1.5);

  void _zoom(double scale, [Offset? anchor]) {
    scale = scale.clamp(1.0, 5.0);
    if (scale == 1) {
      reset();
      return;
    }
    final point = anchor ?? _viewport.center(Offset.zero);
    final scene = _transform.toScene(point);
    final offset = point - scene * scale;
    _transform.value = Matrix4.diagonal3Values(scale, scale, 1)
      ..setTranslationRaw(
        offset.dx.clamp(_viewport.width * (1 - scale), 0).toDouble(),
        offset.dy.clamp(_viewport.height * (1 - scale), 0).toDouble(),
        0,
      );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _viewport = constraints.biggest;
      final canScroll = !_zoomed && _pointers.length < 2;
      return Listener(
        onPointerDown: (event) => _pointer(event.pointer, true),
        onPointerUp: (event) => _pointer(event.pointer, false),
        onPointerCancel: (event) => _pointer(event.pointer, false),
        child: GestureDetector(
          onDoubleTapDown: (details) =>
              _doubleTapPosition = details.localPosition,
          onDoubleTap: () {
            if (_zoomed) {
              reset();
            } else {
              _zoom(2.5, _doubleTapPosition);
            }
          },
          child: InteractiveViewer(
            transformationController: _transform,
            minScale: 1,
            maxScale: 5,
            panEnabled: _zoomed,
            scaleEnabled: true,
            child: widget.builder(canScroll),
          ),
        ),
      );
    },
  );
}
