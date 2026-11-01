import 'package:flutter/foundation.dart';

import '../models/models.dart';

class MangaChapter {
  final int index;
  final int firstPage;
  final MangaWatch watch;

  const MangaChapter(this.index, this.firstPage, this.watch);
}

class MangaPageLocation {
  final MangaChapter chapter;
  final int page;

  const MangaPageLocation(this.chapter, this.page);
}

/// A lazily extended strip. Appending chapters keeps every existing list index
/// stable; preloading never changes the chapter the user is actually reading.
class MangaChapters extends ChangeNotifier {
  final int episodeCount;
  final Future<MangaWatch> Function(int index) load;
  final Duration timeout;
  final List<MangaChapter> _chapters;
  bool _disposed = false;
  bool loading = false;
  Object? error;

  MangaChapters({
    required int initialIndex,
    required MangaWatch initialWatch,
    required this.episodeCount,
    required this.load,
    this.timeout = const Duration(seconds: 45),
  }) : _chapters = [MangaChapter(initialIndex, 0, initialWatch)];

  int get pageCount =>
      _chapters.last.firstPage + _chapters.last.watch.urls.length;
  bool get hasNext => _chapters.last.index + 1 < episodeCount;

  MangaPageLocation? locate(int position) {
    if (position < 0 || position >= pageCount) return null;
    var low = 0;
    var high = _chapters.length - 1;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      if (_chapters[mid].firstPage <= position) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    final chapter = _chapters[low];
    return MangaPageLocation(chapter, position - chapter.firstPage);
  }

  int globalPage(int chapterIndex, int page) =>
      _chapters.firstWhere((c) => c.index == chapterIndex).firstPage + page;

  void prefetch(int lastVisiblePage) {
    // Only fetch while approaching the tail, never for offscreen cached items
    // and never repeatedly retry a failure as the user continues scrolling.
    if (lastVisiblePage >= _chapters.last.firstPage &&
        lastVisiblePage >= pageCount - 3 &&
        error == null) {
      loadNext();
    }
  }

  Future<void> loadNext() async {
    if (_disposed || loading || !hasNext) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final next = _chapters.last.index + 1;
      final watch = await load(next).timeout(timeout);
      if (_disposed) return;
      if (watch.urls.isEmpty) throw StateError('下一章没有可阅读的图片');
      _chapters.add(MangaChapter(next, pageCount, watch));
    } catch (e) {
      if (!_disposed) error = e;
    } finally {
      if (!_disposed) {
        loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
