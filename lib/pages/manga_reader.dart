import 'package:flutter/material.dart';

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
  late PageController _pageCtrl;

  MediaEpisode get _episode => widget.group.urls[_index];

  @override
  void initState() {
    super.initState();
    _pageCtrl = PageController();
    _load();
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _watch = null;
      _error = null;
      _page = 0;
    });
    try {
      final raw = await Sources.watch(widget.item, _episode.url);
      if (!mounted) return;
      setState(() => _watch = MangaWatch.fromJson(raw));
      await Storage.saveHistory(HistoryRecord(
        key: widget.item.key,
        episodeUrl: _episode.url,
        episodeName: _episode.name,
        groupIndex: widget.groupIndex,
        episodeIndex: _index,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  void _go(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.group.urls.length) return;
    setState(() => _index = next);
    _load();
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
      onPageChanged: (i) => setState(() => _page = i),
      itemBuilder: (context, i) => InteractiveViewer(
        maxScale: 5,
        child: _image(watch.urls[i], watch),
      ),
    );
  }

  Widget _buildWebtoon(MangaWatch watch) {
    return ListView.builder(
      itemCount: watch.urls.length,
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
                  setState(() => _webtoon = !_webtoon);
                  Storage.setSetting('mangaWebtoon', _webtoon);
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
                child: _webtoon
                    ? const SizedBox()
                    : Slider(
                        value: (_page + 1).toDouble().clamp(1, watch.urls.length.toDouble()),
                        min: 1,
                        max: watch.urls.length.toDouble(),
                        divisions: watch.urls.length > 1 ? watch.urls.length - 1 : 1,
                        label: '${_page + 1}/${watch.urls.length}',
                        onChanged: (v) => _pageCtrl.jumpToPage(v.toInt() - 1),
                      ),
              ),
              if (!_webtoon)
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
