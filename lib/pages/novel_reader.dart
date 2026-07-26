import 'dart:async';

import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../models/models.dart';
import '../models/reader_settings.dart';
import '../services/sources.dart';
import '../services/storage.dart';
import '../widgets/novel_settings_sheet.dart';
import '../widgets/source_image.dart';

class NovelReaderPage extends StatefulWidget {
  final MediaItem item;
  final MediaEpisodeGroup group;
  final int groupIndex;
  final int index;

  const NovelReaderPage({
    super.key,
    required this.item,
    required this.group,
    required this.groupIndex,
    required this.index,
  });

  @override
  State<NovelReaderPage> createState() => _NovelReaderPageState();
}

class _NovelReaderPageState extends State<NovelReaderPage> {
  late int _index = widget.index;
  NovelWatch? _watch;
  String? _error;
  bool _showBars = true;

  final NovelReaderSettings _settings = NovelReaderSettings.load();

  // Paragraph heights change with every typography tweak, so the position is
  // tracked by block index rather than scroll offset — an offset would land
  // somewhere else the moment the font size or line height is adjusted.
  final ItemScrollController _itemCtrl = ItemScrollController();
  final ItemPositionsListener _itemPositions = ItemPositionsListener.create();

  int _block = 0;
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
    // Leaving a chapter that never loaded must not overwrite a real position.
    if (_watch != null) _persist(_block);
    super.dispose();
  }

  void _onScroll() {
    final positions = _itemPositions.itemPositions.value;
    if (positions.isEmpty) return;
    final first = positions
        .where((p) => p.itemTrailingEdge > 0)
        .fold<int?>(null, (min, p) => min == null || p.index < min ? p.index : min);
    if (first != null && first != _block) {
      _block = first;
      _scheduleSave(first);
    }
  }

  void _scheduleSave(int block) {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 600), () => _persist(block));
  }

  void _persist(int block) {
    Storage.saveHistory(HistoryRecord(
      key: widget.item.key,
      episodeUrl: _episode.url,
      episodeName: _episode.name,
      groupIndex: widget.groupIndex,
      episodeIndex: _index,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      position: block,
    ));
  }

  Future<void> _load({bool restore = false}) async {
    var start = 0;
    if (restore) {
      final history = Storage.historyOf(widget.item.key);
      if (history != null &&
          history.groupIndex == widget.groupIndex &&
          history.episodeIndex == _index) {
        start = history.position;
      }
    }

    setState(() {
      _watch = null;
      _error = null;
      _block = start;
    });

    try {
      final raw = await Sources.watchCached(widget.item, _episode.url);
      if (!mounted) return;
      final watch = NovelWatch.fromJson(raw);
      // +1 for the title block the list renders ahead of the content.
      final block = start.clamp(0, watch.blocks.isEmpty ? 0 : watch.blocks.length);
      setState(() {
        _watch = watch;
        _block = block;
      });
      _persist(block);
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

  Widget _illustration(String url, NovelWatch watch) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar:
              AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
          body: Center(
            child: InteractiveViewer(
              maxScale: 5,
              child: SourceImage(
                url: url,
                package: widget.item.package,
                netMode: watch.netMode,
                headers: watch.headers,
              ),
            ),
          ),
        ),
      )),
      child: SourceImage(
        url: url,
        package: widget.item.package,
        netMode: watch.netMode,
        headers: watch.headers,
        fit: BoxFit.fitWidth,
        placeholder: const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
        error: Container(
          padding: const EdgeInsets.all(16),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.broken_image_outlined),
              SizedBox(width: 8),
              Text('插图加载失败'),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final watch = _watch;
    final background = _settings.background(context);
    final foreground = _settings.foreground(context);

    return Scaffold(
      backgroundColor: background,
      appBar: _showBars
          ? AppBar(
              backgroundColor: background,
              foregroundColor: foreground,
              elevation: 0,
              title: Text(_episode.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16)),
              actions: [
                IconButton(
                  tooltip: '阅读设置',
                  icon: const Icon(Icons.text_format),
                  onPressed: () => NovelSettingsSheet.show(
                    context,
                    _settings,
                    // Re-render the page under the sheet on every tweak.
                    () => setState(() {}),
                  ),
                ),
              ],
            )
          : null,
      body: SafeArea(
        child: _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('加载失败\n$_error',
                          textAlign: TextAlign.center,
                          maxLines: 8,
                          style: TextStyle(color: foreground)),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                ),
              )
            : watch == null
                ? const Center(child: CircularProgressIndicator())
                : GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () => setState(() => _showBars = !_showBars),
                    child: SelectionArea(child: _buildContent(watch)),
                  ),
      ),
      bottomNavigationBar: _showBars ? _buildBottomBar(background, foreground) : null,
    );
  }

  Widget _buildContent(NovelWatch watch) {
    final style = _settings.textStyle(context);
    final indent = _settings.indentFirstLine ? '　　' : '';

    return ScrollablePositionedList.builder(
      itemScrollController: _itemCtrl,
      itemPositionsListener: _itemPositions,
      initialScrollIndex: _block,
      // The key must identify the chapter as well as the typography. Keeping
      // one key across chapters lets PageStorage restore the previous
      // chapter's scroll offset, so the next chapter opens at the bottom
      // instead of at its start.
      key: ValueKey('${_episode.url}|${_settings.fontSize}|'
          '${_settings.lineHeight}|${_settings.fontName}|'
          '${_settings.letterSpacing}|${_settings.paragraphSpacing}|'
          '${_settings.horizontalPadding}'),
      padding: EdgeInsets.symmetric(
        horizontal: _settings.horizontalPadding,
        vertical: _settings.verticalPadding,
      ),
      itemCount: watch.blocks.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: EdgeInsets.only(bottom: _settings.paragraphSpacing + 8),
            child: Text(
              watch.subtitle.isNotEmpty ? watch.subtitle : _episode.name,
              style: style.copyWith(
                fontSize: _settings.fontSize * 1.4,
                fontWeight: FontWeight.w700,
                height: 1.4,
              ),
            ),
          );
        }
        final block = watch.blocks[i - 1];
        if (block.isImage) {
          return Padding(
            padding: EdgeInsets.symmetric(vertical: _settings.paragraphSpacing),
            child: _illustration(block.imageUrl, watch),
          );
        }
        return Padding(
          padding: EdgeInsets.only(bottom: _settings.paragraphSpacing),
          child: Text(
            '$indent${block.text}',
            style: style,
            textAlign:
                _settings.justify ? TextAlign.justify : TextAlign.start,
          ),
        );
      },
    );
  }

  Widget _buildBottomBar(Color background, Color foreground) {
    final total = _watch?.blocks.length ?? 0;
    final percent = total == 0 ? 0 : ((_block / total) * 100).clamp(0, 100).round();

    return BottomAppBar(
      color: background,
      elevation: 0,
      height: 56,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          TextButton.icon(
            icon: const Icon(Icons.chevron_left),
            label: const Text('上一章'),
            style: TextButton.styleFrom(foregroundColor: foreground),
            onPressed: _index > 0 ? () => _go(-1) : null,
          ),
          Text(
            '${_index + 1}/${widget.group.urls.length}'
            '${total == 0 ? '' : '  ·  $percent%'}',
            style: TextStyle(color: foreground, fontSize: 12),
          ),
          TextButton.icon(
            icon: const Icon(Icons.chevron_right),
            label: const Text('下一章'),
            iconAlignment: IconAlignment.end,
            style: TextButton.styleFrom(foregroundColor: foreground),
            onPressed:
                _index < widget.group.urls.length - 1 ? () => _go(1) : null,
          ),
        ],
      ),
    );
  }
}
