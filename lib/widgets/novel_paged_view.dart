import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../models/reader_settings.dart';
import '../services/novel_pagination.dart';

class NovelPagedView extends StatefulWidget {
  final NovelWatch watch;
  final String title;
  final NovelReaderSettings settings;
  final NovelPosition position;
  final ValueChanged<NovelPosition> onPositionChanged;
  final VoidCallback onCenterTap;
  final VoidCallback? onPreviousChapter;
  final VoidCallback? onNextChapter;
  final Widget Function(String url) imageBuilder;

  const NovelPagedView({
    super.key,
    required this.watch,
    required this.title,
    required this.settings,
    required this.position,
    required this.onPositionChanged,
    required this.onCenterTap,
    required this.imageBuilder,
    this.onPreviousChapter,
    this.onNextChapter,
  });

  @override
  State<NovelPagedView> createState() => _NovelPagedViewState();
}

class _NovelPagedViewState extends State<NovelPagedView> {
  PageController? _controller;
  NovelPagination? _layout;
  Object? _layoutKey;
  late NovelPosition _position = widget.position;
  int _page = 0;
  int _gestureStartPage = 0;
  double _overscroll = 0;
  bool _chapterRequested = false;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _turn(int delta) {
    final next = _page + delta;
    if (next >= 0 && next < _layout!.pages.length) {
      _controller?.animateToPage(
        next,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    } else if (!_chapterRequested) {
      final callback = delta > 0
          ? widget.onNextChapter
          : widget.onPreviousChapter;
      if (callback != null) {
        _chapterRequested = true;
        callback();
      }
    }
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification) {
      _gestureStartPage = _page;
      _overscroll = 0;
    } else if (notification is OverscrollNotification &&
        notification.dragDetails != null) {
      final forward = notification.overscroll > 0;
      if ((forward && _gestureStartPage == _layout!.pages.length - 1) ||
          (!forward && _gestureStartPage == 0)) {
        _overscroll += notification.overscroll;
        if (_overscroll.abs() >= 60) _turn(forward ? 1 : -1);
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final style = DefaultTextStyle.of(
      context,
    ).style.merge(settings.textStyle(context));
    final titleStyle = style.copyWith(
      fontSize: settings.fontSize * 1.4,
      fontWeight: FontWeight.w700,
      height: 1.4,
    );
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontal = math.min(
          settings.horizontalPadding,
          constraints.maxWidth / 3,
        );
        final vertical = math.min(
          settings.verticalPadding,
          math.max(0.0, (constraints.maxHeight - 28) / 3),
        );
        final size = Size(
          math.max(1.0, constraints.maxWidth - horizontal * 2),
          math.max(1.0, constraints.maxHeight - vertical * 2 - 28),
        );
        final key = (
          widget.watch,
          widget.title,
          size,
          style,
          titleStyle,
          scaler,
          direction,
          settings.indentFirstLine,
          settings.justify,
          settings.paragraphSpacing,
        );
        if (key != _layoutKey) {
          _layoutKey = key;
          _layout = NovelPagination.layout(
            blocks: widget.watch.blocks,
            title: widget.title,
            size: size,
            style: style,
            titleStyle: titleStyle,
            textScaler: scaler,
            direction: direction,
            indent: settings.indentFirstLine,
            justify: settings.justify,
            paragraphSpacing: settings.paragraphSpacing,
          );
          _page = _layout!.pageFor(_position);
          final previous = _controller;
          _controller = PageController(initialPage: _page, keepPage: false);
          if (previous != null) {
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => previous.dispose(),
            );
          }
        }
        final pages = _layout!.pages;
        return Focus(
          autofocus: true,
          onKeyEvent: (node, event) {
            if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
              return KeyEventResult.ignored;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
                event.logicalKey == LogicalKeyboardKey.pageDown) {
              _turn(1);
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                event.logicalKey == LogicalKeyboardKey.pageUp) {
              _turn(-1);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: SelectionArea(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (event) {
                final fraction = event.localPosition.dx / constraints.maxWidth;
                if (fraction < 0.28) {
                  _turn(-1);
                } else if (fraction > 0.72) {
                  _turn(1);
                } else {
                  widget.onCenterTap();
                }
              },
              child: Column(
                children: [
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: horizontal,
                        vertical: vertical,
                      ),
                      child: NotificationListener<ScrollNotification>(
                        onNotification: _onScroll,
                        child: PageView.builder(
                          key: ValueKey(_layoutKey),
                          controller: _controller,
                          physics: const ClampingScrollPhysics(),
                          itemCount: pages.length,
                          onPageChanged: (page) {
                            setState(() {
                              _page = page;
                              _position = pages[page].start;
                            });
                            widget.onPositionChanged(_position);
                          },
                          itemBuilder: (context, page) {
                            final content = pages[page];
                            if (content.fragments.singleOrNull?.imageUrl
                                case final String url) {
                              return SizedBox.expand(
                                child: widget.imageBuilder(url),
                              );
                            }
                            return Align(
                              alignment: Alignment.topLeft,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.topLeft,
                                child: SizedBox(
                                  width: size.width,
                                  height: math.max(size.height, content.height),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      for (final part in content.fragments)
                                        SizedBox(
                                          height: part.height + part.gap,
                                          child: Padding(
                                            padding: EdgeInsets.only(
                                              bottom: part.gap,
                                            ),
                                            child: Text(
                                              part.displayText,
                                              style: part.title
                                                  ? titleStyle
                                                  : style,
                                              textScaler: scaler,
                                              textAlign:
                                                  !part.title &&
                                                      settings.justify
                                                  ? TextAlign.justify
                                                  : TextAlign.start,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 28,
                    child: Center(
                      child: Text(
                        '${_page + 1} / ${pages.length}',
                        key: const ValueKey('novel-page-counter'),
                        style: TextStyle(
                          fontSize: 12,
                          color: settings.foreground(context),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
