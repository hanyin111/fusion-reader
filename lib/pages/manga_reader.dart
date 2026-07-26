import 'dart:async';

import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../models/models.dart';
import '../services/sources.dart';
import '../services/storage.dart';
import '../widgets/source_image.dart';

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
    _itemPositions.itemPositions.removeListener(_onScroll);
    // Persist wherever the reader stopped, without waiting for the debounce.
    // Only once the chapter actually loaded: backing out of a still-loading
    // chapter would otherwise write page 0 over a real saved position.
    if (_watch != null) _persist(_page);
    _pageCtrl?.dispose();
    super.dispose();
  }

  void _onScroll() {
    final positions = _itemPositions.itemPositions.value;
    if (positions.isEmpty) return;
    // The topmost item that is still at least partly on screen.
    final first = positions
        .where((p) => p.itemTrailingEdge > 0)
        .fold<int?>(null, (min, p) => min == null || p.index < min ? p.index : min);
    if (first != null && first != _page) {
      setState(() => _page = first);
      _scheduleSave(first);
    }
  }

  void _scheduleSave(int page) {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 600), () => _persist(page));
  }

  void _persist(int page) {
    Storage.saveHistory(HistoryRecord(
      key: widget.item.key,
      episodeUrl: _episode.url,
      episodeName: _episode.name,
      groupIndex: widget.groupIndex,
      episodeIndex: _index,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      position: page,
    ));
  }

  Future<void> _load({bool restore = false}) async {
    // Only the episode the reader was opened at resumes mid-chapter; moving to
    // another chapter starts it from the beginning.
    var startPage = 0;
    if (restore) {
      final history = Storage.historyOf(widget.item.key);
      if (history != null &&
          history.groupIndex == widget.groupIndex &&
          history.episodeIndex == _index) {
        startPage = history.position;
      }
    }

    setState(() {
      _watch = null;
      _error = null;
      _page = startPage;
    });

    try {
      final raw = await Sources.watchCached(widget.item, _episode.url);
      if (!mounted) return;
      final watch = MangaWatch.fromJson(raw);
      final page = startPage.clamp(0, watch.urls.isEmpty ? 0 : watch.urls.length - 1);
      setState(() {
        _watch = watch;
        _page = page;
        // Build the controller with the resume page baked in so paged mode
        // never renders page one first.
        _pageCtrl?.dispose();
        _pageCtrl = PageController(initialPage: page);
      });
      _persist(page);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  void _go(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.group.urls.length) return;
    _saveDebounce?.cancel();
    setState(() => _index = next);
    _load();
  }

  void _jumpTo(int page) {
    setState(() => _page = page);
    if (_webtoon) {
      if (_itemCtrl.isAttached) _itemCtrl.jumpTo(index: page);
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
                          Text('加载失败\n$_error',
                              style: const TextStyle(color: Colors.white),
                              textAlign: TextAlign.center,
                              maxLines: 8),
                          const SizedBox(height: 12),
                          FilledButton(onPressed: _load, child: const Text('重试')),
                        ],
                      ),
                    )
                  : watch == null
                      ? const Center(child: CircularProgressIndicator())
                      : _webtoon
                          ? _buildWebtoon(watch)
                          : _buildPaged(watch),
            ),
          ),
          if (_showBar) _buildTopBar(),
          if (_showBar && watch != null) _buildBottomBar(watch),
        ],
      ),
    );
  }

  Widget _image(String url, MangaWatch watch, {BoxFit fit = BoxFit.contain}) {
    return SourceImage(
      url: url,
      package: widget.item.package,
      netMode: watch.netMode,
      headers: watch.headers,
      fit: fit,
      error: const Center(child: Icon(Icons.broken_image, color: Colors.white54)),
    );
  }

  Widget _buildPaged(MangaWatch watch) {
    return PageView.builder(
      controller: _pageCtrl,
      itemCount: watch.urls.length,
      onPageChanged: (i) {
        setState(() => _page = i);
        _scheduleSave(i);
      },
      itemBuilder: (context, i) => InteractiveViewer(
        maxScale: 5,
        child: _image(watch.urls[i], watch),
      ),
    );
  }

  Widget _buildWebtoon(MangaWatch watch) {
    return ScrollablePositionedList.builder(
      // Keyed per chapter so PageStorage cannot carry the previous chapter's
      // scroll offset into this one.
      key: ValueKey('webtoon|${_episode.url}'),
      itemCount: watch.urls.length,
      itemScrollController: _itemCtrl,
      itemPositionsListener: _itemPositions,
      initialScrollIndex: _page,
      itemBuilder: (context, i) => _image(watch.urls[i], watch, fit: BoxFit.fitWidth),
    );
  }

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
              IconButton(
                tooltip: _webtoon ? '切换为翻页模式' : '切换为条漫模式',
                icon: Icon(_webtoon ? Icons.auto_stories : Icons.view_day,
                    color: Colors.white),
                onPressed: () {
                  // Carry the current page across the mode switch.
                  final page = _page;
                  setState(() {
                    _webtoon = !_webtoon;
                    _pageCtrl?.dispose();
                    _pageCtrl = PageController(initialPage: page);
                  });
                  Storage.setSetting('mangaWebtoon', _webtoon);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (_webtoon && _itemCtrl.isAttached) {
                      _itemCtrl.jumpTo(index: page);
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
          child: Row(
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
                        value: (_page + 1)
                            .toDouble()
                            .clamp(1, watch.urls.length.toDouble()),
                        min: 1,
                        max: watch.urls.length.toDouble(),
                        divisions: watch.urls.length - 1,
                        label: '${_page + 1}/${watch.urls.length}',
                        onChanged: (v) => _jumpTo(v.toInt() - 1),
                      ),
              ),
              Text('${_page + 1}/${watch.urls.length}',
                  style: const TextStyle(color: Colors.white)),
              IconButton(
                tooltip: '下一章',
                icon: const Icon(Icons.skip_next, color: Colors.white),
                onPressed:
                    _index < widget.group.urls.length - 1 ? () => _go(1) : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
