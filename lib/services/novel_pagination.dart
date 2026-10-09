import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/models.dart';

/// A content anchor, independent of font, viewport and generated page number.
class NovelPosition {
  final int block;
  final int offset;
  const NovelPosition(this.block, [this.offset = 0]);

  int compareTo(NovelPosition other) => block == other.block
      ? offset.compareTo(other.offset)
      : block.compareTo(other.block);
}

class NovelPageFragment {
  final NovelPosition start;
  final int endOffset;
  final String text;
  final String? imageUrl;
  final bool title;
  final bool indented;
  final double height;
  final double gap;

  const NovelPageFragment({
    required this.start,
    required this.endOffset,
    required this.height,
    this.text = '',
    this.imageUrl,
    this.title = false,
    this.indented = false,
    this.gap = 0,
  });

  String get displayText => '${indented ? '　　' : ''}$text';
}

class NovelPage {
  final List<NovelPageFragment> fragments;
  NovelPage(List<NovelPageFragment> fragments)
    : fragments = List.unmodifiable(fragments);
  NovelPosition get start => fragments.first.start;
  double get height =>
      fragments.fold(0, (sum, part) => sum + part.height + part.gap);
}

class NovelPagination {
  final List<NovelPage> pages;
  NovelPagination._(List<NovelPage> pages) : pages = List.unmodifiable(pages);

  int pageFor(NovelPosition position) {
    var fallback = 0;
    for (var i = 0; i < pages.length; i++) {
      if (pages[i].start.compareTo(position) <= 0) fallback = i;
      for (final part in pages[i].fragments) {
        if (part.start.block == position.block &&
            (part.imageUrl != null ||
                (part.start.offset <= position.offset &&
                    position.offset < part.endOffset))) {
          return i;
        }
      }
    }
    return fallback;
  }

  factory NovelPagination.layout({
    required List<NovelBlock> blocks,
    required String title,
    required Size size,
    required TextStyle style,
    required TextStyle titleStyle,
    required TextScaler textScaler,
    required TextDirection direction,
    required bool indent,
    required bool justify,
    required double paragraphSpacing,
  }) {
    final width = math.max(1.0, size.width);
    final height = math.max(1.0, size.height);
    final pages = <NovelPage>[];
    var fragments = <NovelPageFragment>[];
    var used = 0.0;

    void flush() {
      if (fragments.isEmpty) return;
      pages.add(NovelPage(fragments));
      fragments = [];
      used = 0;
    }

    void addText(int block, String text, {bool isTitle = false}) {
      if (text.isEmpty) return;
      // UTF-16 offsets match Flutter's text APIs. Split only at grapheme
      // boundaries so emoji, combining marks and surrogate pairs stay intact.
      final boundaries = <int>[0];
      for (final grapheme in text.characters) {
        boundaries.add(boundaries.last + grapheme.length);
      }
      var start = 0;
      final painter = TextPainter(
        textDirection: direction,
        textScaler: textScaler,
        textAlign: !isTitle && justify ? TextAlign.justify : TextAlign.start,
      );
      try {
        while (start < boundaries.length - 1) {
          final indented = !isTitle && indent && start == 0;
          final remaining = boundaries.length - 1 - start;
          final measurements = <int, double>{};
          double measure(int count) => measurements.putIfAbsent(count, () {
            painter.text = TextSpan(
              text:
                  '${indented ? '　　' : ''}${text.substring(boundaries[start], boundaries[start + count])}',
              style: isTitle ? titleStyle : style,
            );
            painter.layout(maxWidth: width);
            return painter.height;
          });

          final available = height - used;
          // Exponential bounds keep each layout small even when a source
          // returns a whole chapter as one very long paragraph.
          var low = 0;
          var high = math.min(64, remaining);
          while (measure(high) <= available + 0.01) {
            low = high;
            if (high == remaining) break;
            high = math.min(high * 2, remaining);
          }
          while (low < high) {
            final middle = (low + high + 1) ~/ 2;
            if (measure(middle) <= available + 0.01) {
              low = middle;
            } else {
              high = middle - 1;
            }
          }
          if (low == 0 && fragments.isNotEmpty) {
            flush();
            continue;
          }
          // Even an oversized glyph must advance. The view scales such a
          // page down only when the available space cannot hold one line.
          var count = math.max(1, low);
          var end = boundaries[start + count];
          if (end < text.length &&
              RegExp(r'[A-Za-z0-9]').hasMatch(text[end - 1]) &&
              RegExp(r'[A-Za-z0-9]').hasMatch(text[end])) {
            final prefix = text.substring(boundaries[start], end);
            final breakAt = prefix.lastIndexOf(RegExp(r'\s')) + 1;
            if (breakAt > prefix.length ~/ 2) {
              final boundary = boundaries.indexOf(
                boundaries[start] + breakAt,
                start + 1,
              );
              if (boundary > start) {
                count = boundary - start;
                end = boundaries[boundary];
              }
            }
          }
          final measuredHeight = measure(count);
          final isEnd = start + count == boundaries.length - 1;
          final gap = isEnd
              ? math.min(
                  paragraphSpacing + (isTitle ? 8 : 0),
                  math.max(0.0, available - measuredHeight),
                )
              : 0.0;
          fragments.add(
            NovelPageFragment(
              start: NovelPosition(block, boundaries[start]),
              endOffset: end,
              text: text.substring(boundaries[start], end),
              title: isTitle,
              indented: indented,
              height: measuredHeight,
              gap: gap,
            ),
          );
          used += measuredHeight + gap;
          start += count;
          if (!isEnd) flush();
        }
      } finally {
        painter.dispose();
      }
    }

    addText(0, title, isTitle: true);
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      if (block.isImage) {
        flush();
        fragments.add(
          NovelPageFragment(
            start: NovelPosition(i + 1),
            endOffset: 0,
            height: height,
            imageUrl: block.imageUrl,
          ),
        );
        flush();
      } else {
        addText(i + 1, block.text);
      }
    }
    flush();
    if (pages.isEmpty) {
      pages.add(
        NovelPage(const [
          NovelPageFragment(start: NovelPosition(0), endOffset: 0, height: 0),
        ]),
      );
    }
    return NovelPagination._(pages);
  }
}
