import 'dart:async';

import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../models/models.dart';
import '../services/sources.dart';
import '../services/storage.dart';
import '../services/manga_chapters.dart';
import '../widgets/source_image.dart';
import '../widgets/comments_button.dart';
import '../widgets/manga_zoom_view.dart';

class MangaReaderPage extends StatefulWidget {
  final MediaItem item;
  final MediaEpisodeGroup group;
  final int groupIndex;
  final int index;

  const MangaReaderPage({
    super.key,
    required this.item,
    required this.group,
    required this.groupIndex,
    required this.index,
  });

  @override
  State<MangaReaderPage> createState() => _MangaReaderPageState();
}

class _MangaReaderPageState extends State<MangaReaderPage> {
  late int _index = widget.index;
  MangaWatch? _watch;
  String? _error;
  bool _webtoon = Storage.setting('mangaWebtoon', defaultValue: false) as bool;
  bool _showBar = true;
  int _page = 0;
  int _zoomPercent = 100;
  final _zoomKey = GlobalKey<MangaZoomViewState>();
  MangaChapters? _chapters;
  int _loadGeneration = 0;
  int _initialStripPage = 0;

  PageController? _pageCtrl;

  // Webtoon strips are variable-height and load lazily, so an offset-based
  // ListView cannot restore a position: the images below have not been sized
  // yet and the scroll collapses back to the top. Addressing pages by index
  // instead keeps the restore stable no matter when the images arrive.
  final ItemScrollController _itemCtrl = ItemScrollController();
  final ItemPositionsListener _itemPositions = ItemPositionsListener.create();

  Timer? _saveDebounce;

  MediaEpisode get _episode => widget.group.urls[_index];

  @override
  void initState() {
    super.initState();
    _itemPositions.itemPositions.addListener(_onScroll);
    _load(restore: true);
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _loadGeneration++;
    _chapters?.dispose();
    _itemPositions.itemPositions.removeListener(_onScroll);
    // Persist wherever the reader stopped, without waiting for the debounce.
    // Only once the chapter actually loaded: backing out of a still-loading
    // chapter would otherwise write page 0 over a real saved position.
    if (_watch != null) _persist(_page);
    _pageCtrl?.dispose();
    super.dispose();
  }

  void _onScroll() {
    final chapters = _chapters;
    if (!_webtoon || _watch == null || chapters == null) return;
    final positions = _itemPositions.itemPositions.value;
    final visible = positions.where(
      (p) => p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1,
    );
    if (visible.isEmpty) return;
    // The topmost item that is still at least partly on screen.
    final first = visible.fold<int?>(
      null,
      (min, p) => min == null || p.index < min ? p.index : min,
    );
    // The footer belongs to the end of the final image, not to a new chapter.
    final location = chapters.locate(first!.clamp(0, chapters.pageCount - 1));
    if (location != null &&
        (location.chapter.index != _index || location.page != _page)) {
      setState(() {
        _index = location.chapter.index;
        _watch = location.chapter.watch;
        _page = location.page;
      });
      _scheduleSave(_page);
    }
    chapters.prefetch(
      visible.map((p) => p.index).reduce((a, b) => a > b ? a : b),
    );
  }

  void _scheduleSave(int page) {
    _saveDebounce?.cancel();
    final record = _record(page);
    _saveDebounce = Timer(
      const Duration(milliseconds: 600),
      () => Storage.saveHistory(record, item: widget.item),
    );
  }

  HistoryRecord _record(int page) => HistoryRecord(
    key: widget.item.key,
    episodeUrl: _episode.url,
    episodeName: _episode.name,
    groupIndex: widget.groupIndex,
    episodeIndex: _index,
    timestamp: DateTime.now().millisecondsSinceEpoch,
    position: page,
  );

  void _persist(int page) {
    Storage.saveHistory(_record(page), item: widget.item);
  }

  Future<void> _load({bool restore = false}) async {
    final generation = ++_loadGeneration;
    final chapterIndex = _index;
    final episode = _episode;
    _saveDebounce?.cancel();
    _chapters?.dispose();
    _chapters = null;
    // Cached chapters can resolve before the loading frame is painted, reusing
    // the same zoom view. Reset its transform explicitly when changing chapters.
    _zoomKey.currentState?.reset();
    // Only the episode the reader was opened at resumes mid-chapter; moving to
    // another chapter starts it from the beginning.
    var startPage = 0;
    if (restore) {
      final history = Storage.historyOf(widget.item.key);
      if (history != null && history.episodeUrl == _episode.url) {
        startPage = history.position;
      }
    }

    setState(() {
      _watch = null;
      _error = null;
      _page = startPage;
      _zoomPercent = 100;
    });

    try {
      final raw = await Sources.watchCached(widget.item, episode.url);
      if (!mounted || generation != _loadGeneration) return;
      final watch = MangaWatch.fromJson(raw);
      if (watch.urls.isEmpty) throw StateError('本章没有可阅读的图片');
      final page = startPage.clamp(
        0,
        watch.urls.isEmpty ? 0 : watch.urls.length - 1,
      );
      setState(() {
        _watch = watch;
        _page = page;
        _initialStripPage = page;
        _chapters = MangaChapters(
          initialIndex: chapterIndex,
          initialWatch: watch,
          episodeCount: widget.group.urls.length,
          load: (index) async => MangaWatch.fromJson(
            await Sources.watchCached(
              widget.item,
              widget.group.urls[index].url,
            ),
          ),
        )..addListener(_chaptersChanged);
        // Build the controller with the resume page baked in so paged mode
        // never renders page one first.
        _pageCtrl?.dispose();
        _pageCtrl = PageController(initialPage: page);
      });
      _persist(page);
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _error = e.toString());
    }
  }

  void _chaptersChanged() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onScroll();
    });
  }

  void _go(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.group.urls.length) return;
    _saveDebounce?.cancel();
    if (_watch != null) _persist(_page);
    setState(() => _index = next);
    _load();
  }

  void _jumpTo(int page) {
    _zoomKey.currentState?.reset();
    setState(() => _page = page);
    if (_webtoon) {
      if (_itemCtrl.isAttached) {
        _itemCtrl.jumpTo(index: _chapters!.globalPage(_index, page));
      }
    } else {
      _pageCtrl?.jumpToPage(page);
    }
    _scheduleSave(page);
  }

  @override
  Widget build(BuildContext context) {
    final watch = _watch;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => setState(() => _showBar = !_showBar),
              child: _error != null
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '加载失败\n$_error',
                            style: const TextStyle(color: Colors.white),
                            textAlign: TextAlign.center,
                            maxLines: 8,
                          ),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: _load,
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    )
                  : watch == null
                  ? const Center(child: CircularProgressIndicator())
                  : MangaZoomView(
                      key: _zoomKey,
                      onZoomChanged: (percent) {
                        if (mounted) setState(() => _zoomPercent = percent);
                      },
                      builder: (canScroll) => _webtoon
                          ? _buildWebtoon(canScroll)
                          : _buildPaged(watch, canScroll),
                    ),
            ),
          ),
          if (_showBar) _buildTopBar(),
          if (_showBar && watch != null) _buildBottomBar(watch),
        ],
      ),
    );
  }

  Widget _image(String url, MangaWatch watch, {BoxFit fit = BoxFit.contain}) {
    return MangaWheelRegion(
      child: SourceImage(
        url: url,
        package: widget.item.package,
        netMode: watch.netMode,
        headers: watch.headers,
        fit: fit,
        placeholder: fit == BoxFit.fitWidth
            ? const AspectRatio(
                aspectRatio: 0.7,
                child: Center(child: CircularProgressIndicator()),
              )
            : null,
        error: const SizedBox(
          height: 240,
          child: Center(child: Icon(Icons.broken_image, color: Colors.white54)),
        ),
      ),
    );
  }

  Widget _buildPaged(MangaWatch watch, bool canScroll) {
    return PageView.builder(
      physics: canScroll ? null : const NeverScrollableScrollPhysics(),
      controller: _pageCtrl,
      itemCount: watch.urls.length,
      onPageChanged: (i) {
        _zoomKey.currentState?.reset();
        setState(() => _page = i);
        _scheduleSave(i);
      },
      itemBuilder: (context, i) => _image(watch.urls[i], watch),
    );
  }

  Widget _buildWebtoon(bool canScroll) {
    final chapters = _chapters!;
    return ScrollablePositionedList.builder(
      physics: canScroll ? null : const NeverScrollableScrollPhysics(),
      // Stable while appending and while the visible chapter changes. Only an
      // explicit chapter jump creates a new strip and resets the scroll view.
      key: ValueKey('webtoon|$_loadGeneration'),
      itemCount: chapters.pageCount + 1,
      itemScrollController: _itemCtrl,
      itemPositionsListener: _itemPositions,
      initialScrollIndex: _initialStripPage,
      itemBuilder: (context, i) {
        final location = chapters.locate(i);
        if (location == null) return _buildStripFooter(chapters);
        final chapter = location.chapter;
        final image = _image(
          chapter.watch.urls[location.page],
          chapter.watch,
          fit: BoxFit.fitWidth,
        );
        if (location.page != 0 || chapter.firstPage == 0) return image;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
              child: Text(
                widget.group.urls[chapter.index].name,
                style: const TextStyle(color: Colors.white70),
              ),
            ),
            image,
          ],
        );
      },
    );
  }

  Widget _buildStripFooter(MangaChapters chapters) => MangaWheelRegion(
    child: SizedBox(
      height: 120,
      child: Center(
        child: chapters.loading
            ? const CircularProgressIndicator()
            : chapters.error != null
            ? TextButton.icon(
                onPressed: chapters.loadNext,
                icon: const Icon(Icons.refresh),
                label: const Text('下一章加载失败，点击重试'),
              )
            : Text(
                chapters.hasNext ? '继续下滑，加载下一章' : '已读到最后一章',
                style: const TextStyle(color: Colors.white70),
              ),
      ),
    ),
  );

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        color: Colors.black.withValues(alpha: 0.7),
        child: SafeArea(
          bottom: false,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
              Expanded(
                child: Text(
                  '${widget.item.title} · ${_episode.name}',
                  style: const TextStyle(color: Colors.white),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              CommentsButton(
                item: widget.item,
                episode: _episode,
                color: Colors.white,
              ),
              IconButton(
                tooltip: _webtoon ? '切换为翻页模式' : '切换为条漫模式',
                icon: Icon(
                  _webtoon ? Icons.auto_stories : Icons.view_day,
                  color: Colors.white,
                ),
                onPressed: () {
                  _zoomKey.currentState?.reset();
                  // Carry the current page across the mode switch.
                  final page = _page;
                  setState(() {
                    _webtoon = !_webtoon;
                    _initialStripPage =
                        _chapters?.globalPage(_index, page) ?? page;
                    _pageCtrl?.dispose();
                    _pageCtrl = PageController(initialPage: page);
                  });
                  Storage.setSetting('mangaWebtoon', _webtoon);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && _webtoon && _itemCtrl.isAttached) {
                      _itemCtrl.jumpTo(index: _initialStripPage);
                    }
                  });
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar(MangaWatch watch) {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        color: Colors.black.withValues(alpha: 0.7),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Flexible(
                    child: Text(
                      '双指缩放\n双击放大/还原',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: '缩小',
                    icon: const Icon(Icons.zoom_out, color: Colors.white),
                    onPressed: _zoomPercent > 100
                        ? () => _zoomKey.currentState?.zoomOut()
                        : null,
                  ),
                  TextButton(
                    onPressed: () => _zoomKey.currentState?.reset(),
                    child: Text(
                      '$_zoomPercent%',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  IconButton(
                    tooltip: '放大',
                    icon: const Icon(Icons.zoom_in, color: Colors.white),
                    onPressed: _zoomPercent < 500
                        ? () => _zoomKey.currentState?.zoomIn()
                        : null,
                  ),
                ],
              ),
              Row(
                children: [
                  IconButton(
                    tooltip: '上一章',
                    icon: const Icon(Icons.skip_previous, color: Colors.white),
                    onPressed: _index > 0 ? () => _go(-1) : null,
                  ),
                  Expanded(
                    child: watch.urls.length < 2
                        ? const SizedBox()
                        : Slider(
                            value: (_page + 1).toDouble().clamp(
                              1,
                              watch.urls.length.toDouble(),
                            ),
                            min: 1,
                            max: watch.urls.length.toDouble(),
                            divisions: watch.urls.length - 1,
                            label: '${_page + 1}/${watch.urls.length}',
                            onChanged: (v) => _jumpTo(v.toInt() - 1),
                          ),
                  ),
                  Text(
                    '${_page + 1}/${watch.urls.length}',
                    style: const TextStyle(color: Colors.white),
                  ),
                  IconButton(
                    tooltip: '下一章',
                    icon: const Icon(Icons.skip_next, color: Colors.white),
                    onPressed: _index < widget.group.urls.length - 1
                        ? () => _go(1)
                        : null,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
