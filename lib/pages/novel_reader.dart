import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../models/models.dart';
import '../models/reader_settings.dart';
import '../services/sources.dart';
import '../services/storage.dart';
import '../services/novel_pagination.dart';
import '../widgets/novel_paged_view.dart';
import '../widgets/novel_settings_sheet.dart';
import '../widgets/comments_button.dart';
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

  // Use paragraph and character anchors: pixel offsets and generated page
  // numbers both move when the font or available screen space changes.
  final ItemScrollController _itemCtrl = ItemScrollController();
  final ItemPositionsListener _itemPositions = ItemPositionsListener.create();

  int _block = 0;
  int _textOffset = 0;
  int _loadRequest = 0;
  Size _scrollSize = Size.zero;
  TextStyle? _scrollStyle;
  TextPainter? _measuredText;
  Object? _measureKey;
  Object? _scrollLayoutKey;
  bool _restoringScroll = false;
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
    _measuredText?.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_settings.paged || _watch == null || _restoringScroll) return;
    final positions = _itemPositions.itemPositions.value;
    if (positions.isEmpty) return;
    final first = positions
        .where((p) => p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1)
        .fold<int?>(
          null,
          (min, p) => min == null || p.index < min ? p.index : min,
        );
    if (first == null) return;
    final item = positions.firstWhere((p) => p.index == first);
    final painter = _paragraphPainter(first);
    var offset = 0;
    if (painter != null) {
      final point = painter.getPositionForOffset(
        Offset(
          Directionality.of(context) == TextDirection.rtl
              ? _scrollSize.width
              : 0,
          math.max(0.0, -item.itemLeadingEdge * _scrollSize.height),
        ),
      );
      offset = math.max(
        0,
        painter.getLineBoundary(point).start - _indentLength(first),
      );
    }
    if (first != _block || offset != _textOffset) {
      setState(() {
        _block = first;
        _textOffset = offset;
      });
      _scheduleSave(first);
    }
  }

  int _indentLength(int block) =>
      block > 0 && _settings.indentFirstLine ? 2 : 0;

  TextPainter? _paragraphPainter(int block) {
    final watch = _watch;
    if (watch == null || block > watch.blocks.length) return null;
    if (block > 0 && watch.blocks[block - 1].isImage) return null;
    final text = block == 0
        ? (watch.subtitle.isNotEmpty ? watch.subtitle : _episode.name)
        : watch.blocks[block - 1].text;
    final style = block == 0
        ? (_scrollStyle ?? _settings.textStyle(context)).copyWith(
            fontSize: _settings.fontSize * 1.4,
            fontWeight: FontWeight.w700,
            height: 1.4,
          )
        : _scrollStyle ?? _settings.textStyle(context);
    final width = math.max(
      1.0,
      _scrollSize.width - _settings.horizontalPadding * 2,
    );
    final key = (
      text,
      style,
      width,
      _indentLength(block),
      MediaQuery.textScalerOf(context),
      Directionality.of(context),
      _settings.justify,
      block == 0,
    );
    if (key != _measureKey) {
      _measureKey = key;
      _measuredText?.dispose();
      _measuredText = TextPainter(
        text: TextSpan(
          text: '${_indentLength(block) == 0 ? '' : '　　'}$text',
          style: style,
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        textAlign: block > 0 && _settings.justify
            ? TextAlign.justify
            : TextAlign.start,
      )..layout(maxWidth: width);
    }
    return _measuredText;
  }

  void _scheduleSave(int block) {
    _saveDebounce?.cancel();
    final offset = _textOffset;
    _saveDebounce = Timer(
      const Duration(milliseconds: 600),
      () => _persist(block, textOffset: offset),
    );
  }

  void _persist(int block, {int? textOffset}) {
    Storage.saveHistory(
      HistoryRecord(
        key: widget.item.key,
        episodeUrl: _episode.url,
        episodeName: _episode.name,
        groupIndex: widget.groupIndex,
        episodeIndex: _index,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        position: block,
        textOffset: textOffset ?? _textOffset,
      ),
      item: widget.item,
    );
  }

  Future<void> _load({bool restore = false, bool fromEnd = false}) async {
    final request = ++_loadRequest;
    final episode = _episode;
    var start = 0;
    var offset = 0;
    if (restore) {
      final history = Storage.historyOf(widget.item.key);
      if (history != null && history.episodeUrl == _episode.url) {
        start = history.position;
        offset = history.textOffset;
      }
    }

    setState(() {
      _watch = null;
      _error = null;
      _block = start;
      _textOffset = offset;
    });

    try {
      final raw = await Sources.watchCached(widget.item, episode.url);
      if (!mounted || request != _loadRequest) return;
      final watch = NovelWatch.fromJson(raw);
      // +1 for the title block the list renders ahead of the content.
      final block = fromEnd
          ? watch.blocks.length
          : start.clamp(0, watch.blocks.length);
      final text = block == 0
          ? (watch.subtitle.isNotEmpty ? watch.subtitle : episode.name)
          : watch.blocks[block - 1].text;
      offset = fromEnd ? text.length : offset.clamp(0, text.length);
      setState(() {
        _watch = watch;
        _block = block;
        _textOffset = offset;
      });
      _persist(block);
    } catch (e) {
      if (!mounted || request != _loadRequest) return;
      setState(() => _error = e.toString());
    }
  }

  void _go(int delta, {bool fromEnd = false}) {
    final next = _index + delta;
    if (next < 0 || next >= widget.group.urls.length) return;
    _saveDebounce?.cancel();
    if (_watch != null) _persist(_block);
    setState(() => _index = next);
    _load(fromEnd: fromEnd);
  }

  Widget _illustration(String url, NovelWatch watch, {bool paged = false}) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
            ),
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
        ),
      ),
      child: SourceImage(
        url: url,
        package: widget.item.package,
        netMode: watch.netMode,
        headers: watch.headers,
        fit: paged ? BoxFit.contain : BoxFit.fitWidth,
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
      extendBody: true,
      extendBodyBehindAppBar: true,
      appBar: _showBars
          ? AppBar(
              backgroundColor: background,
              foregroundColor: foreground,
              elevation: 0,
              title: Text(
                _episode.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16),
              ),
              actions: [
                CommentsButton(item: widget.item, episode: _episode),
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
      // Scaffold adds menu heights to the body's MediaQuery padding even
      // when the bars overlay it. Keep the device's own safe-area insets so
      // toggling the menus cannot resize or repaginate the reading canvas.
      body: MediaQuery(
        data: MediaQuery.of(context),
        child: SafeArea(
          child: _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '加载失败\n$_error',
                          textAlign: TextAlign.center,
                          maxLines: 8,
                          style: TextStyle(color: foreground),
                        ),
                        const SizedBox(height: 12),
                        FilledButton(onPressed: _load, child: const Text('重试')),
                      ],
                    ),
                  ),
                )
              : watch == null
              ? const Center(child: CircularProgressIndicator())
              : _settings.paged
              ? NovelPagedView(
                  key: ValueKey(_episode.url),
                  watch: watch,
                  title: watch.subtitle.isNotEmpty
                      ? watch.subtitle
                      : _episode.name,
                  settings: _settings,
                  position: NovelPosition(_block, _textOffset),
                  onCenterTap: () => setState(() => _showBars = !_showBars),
                  onPositionChanged: (position) {
                    setState(() {
                      _block = position.block;
                      _textOffset = position.offset;
                    });
                    _scheduleSave(_block);
                  },
                  onPreviousChapter: _index > 0
                      ? () => _go(-1, fromEnd: true)
                      : null,
                  onNextChapter: _index < widget.group.urls.length - 1
                      ? () => _go(1)
                      : null,
                  imageBuilder: (url) => _illustration(url, watch, paged: true),
                )
              : SelectionArea(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () => setState(() => _showBars = !_showBars),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        _scrollSize = constraints.biggest;
                        _scrollStyle = DefaultTextStyle.of(
                          context,
                        ).style.merge(_settings.textStyle(context));
                        return _buildContent(watch);
                      },
                    ),
                  ),
                ),
        ),
      ),
      bottomNavigationBar: _showBars
          ? _buildBottomBar(background, foreground)
          : null,
    );
  }

  Widget _buildContent(NovelWatch watch) {
    final style = _settings.textStyle(context);
    final indent = _settings.indentFirstLine ? '　　' : '';
    final key = (
      _episode.url,
      style,
      _scrollSize,
      MediaQuery.textScalerOf(context),
      _settings.indentFirstLine,
      _settings.justify,
      _settings.horizontalPadding,
      _settings.verticalPadding,
      _settings.paragraphSpacing,
    );
    if (_scrollLayoutKey != key) {
      _scrollLayoutKey = key;
      _restoringScroll = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _scrollLayoutKey != key) return;
        _restoringScroll = false;
        _onScroll();
      });
    }
    final painter = _paragraphPainter(_block);
    final alignment =
        painter == null || _scrollSize.height <= 0 || _textOffset == 0
        ? 0.0
        : -painter
                  .getOffsetForCaret(
                    TextPosition(
                      offset: (_textOffset + _indentLength(_block)).clamp(
                        0,
                        painter.text!.toPlainText().length,
                      ),
                    ),
                    Rect.zero,
                  )
                  .dy /
              _scrollSize.height;

    return ScrollablePositionedList.builder(
      itemScrollController: _itemCtrl,
      itemPositionsListener: _itemPositions,
      initialScrollIndex: _block,
      initialAlignment: alignment,
      // The key must identify the chapter as well as the typography. Keeping
      // one key across chapters lets PageStorage restore the previous
      // chapter's scroll offset, so the next chapter opens at the bottom
      // instead of at its start.
      key: ValueKey(key),
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
            textAlign: _settings.justify ? TextAlign.justify : TextAlign.start,
          ),
        );
      },
    );
  }

  Widget _buildBottomBar(Color background, Color foreground) {
    final blocks = _watch?.blocks ?? const <NovelBlock>[];
    var total = 0;
    var completed = 0;
    for (var i = 0; i < blocks.length; i++) {
      final length = math.max(1, blocks[i].text.length);
      total += length;
      if (i + 1 < _block) {
        completed += length;
      } else if (i + 1 == _block) {
        completed += _textOffset.clamp(0, length);
      }
    }
    final percent = total == 0
        ? 0
        : ((completed / total) * 100).clamp(0, 100).round();

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
            onPressed: _index < widget.group.urls.length - 1
                ? () => _go(1)
                : null,
          ),
        ],
      ),
    );
  }
}
