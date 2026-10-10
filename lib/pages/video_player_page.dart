import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/models.dart';
import '../services/danmaku_service.dart';
import '../services/player_config.dart';
import '../services/sources.dart';
import '../services/storage.dart';
import '../widgets/danmaku_overlay.dart';

class VideoPlayerPage extends StatefulWidget {
  final MediaItem item;
  final MediaEpisodeGroup group;
  final int groupIndex;
  final int index;

  const VideoPlayerPage({
    super.key,
    required this.item,
    required this.group,
    required this.groupIndex,
    required this.index,
  });

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  late int _index = widget.index;
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  String? _error;
  bool _loading = true;
  int _generation = 0;
  CancelToken? _danmakuRequest;
  DanmakuSource? _danmakuSource;
  late final ValueNotifier<DanmakuDisplay> _danmaku = ValueNotifier(
    DanmakuDisplay(
      enabled: Storage.setting('danmakuEnabled', defaultValue: true) == true,
      opacity: (Storage.setting('danmakuOpacity', defaultValue: .85) as num)
          .toDouble()
          .clamp(.2, 1),
      fontSize: (Storage.setting('danmakuFontSize', defaultValue: 20) as num)
          .toDouble()
          .clamp(14, 30),
      area: (Storage.setting('danmakuArea', defaultValue: .5) as num)
          .toDouble()
          .clamp(.25, .75),
    ),
  );

  static const _rates = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0];
  double _rate = (Storage.setting('playbackRate', defaultValue: 1.0) as num)
      .toDouble();

  MediaEpisode get _episode => widget.group.urls[_index];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _generation++;
    _danmakuRequest?.cancel();
    _danmaku.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final index = _index;
    final episode = widget.group.urls[index];
    _danmakuRequest?.cancel();
    _danmakuSource = null;
    _setComments(message: '此视频暂无在线弹幕，可加载弹幕文件');
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await Sources.watchCached(widget.item, episode.url);
      final watch = AnimeWatch.fromJson(raw);
      if (!mounted || generation != _generation) return;

      final media = await buildMedia(widget.item.package, watch);
      if (!mounted || generation != _generation) return;
      await configurePlayerFor(_player, widget.item.package, watch);
      if (!mounted || generation != _generation) return;
      await _player.open(media);
      // open() resets the rate, so re-apply the chosen speed each episode.
      await _player.setRate(_rate);
      if (!mounted || generation != _generation) return;
      _danmakuSource = watch.danmaku;
      if (watch.danmaku != null) unawaited(_loadDanmaku(generation));
      await Storage.saveHistory(
        HistoryRecord(
          key: widget.item.key,
          episodeUrl: episode.url,
          episodeName: episode.name,
          groupIndex: widget.groupIndex,
          episodeIndex: index,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
        item: widget.item,
      );
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _setComments({
    List<DanmakuComment> comments = const [],
    bool loading = false,
    String? message,
  }) {
    final previous = _danmaku.value;
    _danmaku.value = DanmakuDisplay(
      comments: comments,
      loading: loading,
      message: message,
      enabled: previous.enabled,
      opacity: previous.opacity,
      fontSize: previous.fontSize,
      area: previous.area,
    );
  }

  Future<void> _loadDanmaku(int generation) async {
    final source = _danmakuSource;
    if (source == null) return;
    _danmakuRequest?.cancel();
    final token = _danmakuRequest = CancelToken();
    _setComments(loading: true);
    try {
      final comments = await DanmakuService.load(
        widget.item.package,
        source,
        cancelToken: token,
      );
      if (!mounted || generation != _generation || token.isCancelled) return;
      _setComments(
        comments: comments,
        message: comments.isEmpty ? '这一集暂时没有弹幕' : null,
      );
    } catch (_) {
      if (!mounted || generation != _generation || token.isCancelled) return;
      _setComments(message: '弹幕加载失败，可重试；视频仍可正常播放');
    }
  }

  Future<void> _importDanmaku() async {
    final generation = _generation;
    final selected = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xml', 'json'],
    );
    if (selected == null || !mounted || generation != _generation) return;
    _danmakuRequest?.cancel();
    try {
      final file = selected.files.single;
      if (file.size > 8 * 1024 * 1024 || file.path == null) {
        throw const FormatException('弹幕文件不可用或超过 8 MB');
      }
      final comments = parseDanmaku(
        await File(file.path!).readAsString(),
        file.extension?.toLowerCase() == 'xml' ? 'bilibili' : 'dplayer',
      );
      if (!mounted || generation != _generation) return;
      _setComments(
        comments: comments,
        message: comments.isEmpty ? '文件中没有可播放的弹幕' : null,
      );
    } catch (_) {
      if (!mounted || generation != _generation) return;
      _setComments(message: '弹幕文件读取失败，请选择 Bilibili XML 或 DPlayer JSON 文件');
    }
  }

  Future<void> _danmakuSettings(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ValueListenableBuilder<DanmakuDisplay>(
          valueListenable: _danmaku,
          builder: (context, display, _) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  title: const Text('显示弹幕'),
                  value: display.enabled,
                  subtitle: Text(
                    display.loading
                        ? '正在加载弹幕…'
                        : display.message ??
                              '已加载 ${display.comments.length} 条弹幕',
                  ),
                  onChanged: (value) {
                    _danmaku.value = display.copyWith(enabled: value);
                    Storage.setSetting('danmakuEnabled', value);
                  },
                ),
                _slider(
                  '透明度',
                  display.opacity,
                  .2,
                  1,
                  (value) {
                    _danmaku.value = _danmaku.value.copyWith(opacity: value);
                  },
                  (value) => Storage.setSetting('danmakuOpacity', value),
                ),
                _slider(
                  '字号',
                  display.fontSize,
                  14,
                  30,
                  (value) {
                    _danmaku.value = _danmaku.value.copyWith(fontSize: value);
                  },
                  (value) => Storage.setSetting('danmakuFontSize', value),
                ),
                _slider(
                  '显示区域',
                  display.area,
                  .25,
                  .75,
                  (value) {
                    _danmaku.value = _danmaku.value.copyWith(area: value);
                  },
                  (value) => Storage.setSetting('danmakuArea', value),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      if (_danmakuSource != null)
                        OutlinedButton.icon(
                          onPressed: display.loading
                              ? null
                              : () => _loadDanmaku(_generation),
                          icon: const Icon(Icons.refresh),
                          label: const Text('重新加载'),
                        ),
                      OutlinedButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          _importDanmaku();
                        },
                        icon: const Icon(Icons.file_open_outlined),
                        label: const Text('加载弹幕文件'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> change,
    ValueChanged<double> save,
  ) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Row(
      children: [
        SizedBox(width: 70, child: Text(label)),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            onChanged: change,
            onChangeEnd: save,
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            label == '字号'
                ? value.round().toString()
                : '${(value * 100).round()}%',
          ),
        ),
      ],
    ),
  );

  Widget _videoControls(VideoState state) => Stack(
    fit: StackFit.expand,
    children: [
      ValueListenableBuilder<DanmakuDisplay>(
        valueListenable: _danmaku,
        builder: (context, display, _) =>
            DanmakuOverlay(player: _player, display: display),
      ),
      // The library recreates this builder in its fullscreen route, keeping
      // both the overlay and its settings button available there.
      MaterialVideoControlsTheme(
        normal: kDefaultMaterialVideoControlsThemeData.copyWith(
          topButtonBar: _danmakuButtons(state),
        ),
        fullscreen: kDefaultMaterialVideoControlsThemeDataFullscreen.copyWith(
          topButtonBar: _danmakuButtons(state),
        ),
        child: MaterialDesktopVideoControlsTheme(
          normal: kDefaultMaterialDesktopVideoControlsThemeData.copyWith(
            topButtonBar: _danmakuButtons(state),
          ),
          fullscreen: kDefaultMaterialDesktopVideoControlsThemeDataFullscreen
              .copyWith(topButtonBar: _danmakuButtons(state)),
          child: AdaptiveVideoControls(state),
        ),
      ),
    ],
  );

  List<Widget> _danmakuButtons(VideoState state) => [
    const Spacer(),
    IconButton(
      tooltip: '弹幕设置',
      color: Colors.white,
      icon: const Icon(Icons.subtitles_outlined),
      onPressed: () => _danmakuSettings(state.context),
    ),
  ];

  /// Trim "1.50" down to "1.5" but keep "1.25" intact.
  static String _label(double rate) => rate
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');

  Future<void> _setRate(double rate) async {
    setState(() => _rate = rate);
    await _player.setRate(rate);
    await Storage.setSetting('playbackRate', rate);
  }

  void _go(int delta) {
    if (_loading) return;
    final next = _index + delta;
    if (next < 0 || next >= widget.group.urls.length) return;
    setState(() => _index = next);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          '${widget.item.title} · ${_episode.name}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: '弹幕设置',
            icon: const Icon(Icons.subtitles_outlined),
            onPressed: () => _danmakuSettings(context),
          ),
          PopupMenuButton<double>(
            tooltip: '播放速度',
            initialValue: _rate,
            onSelected: _setRate,
            itemBuilder: (context) => [
              for (final rate in _rates)
                PopupMenuItem(
                  value: rate,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(rate == _rate ? Icons.check : null, size: 16),
                      const SizedBox(width: 8),
                      Text(rate == 1.0 ? '正常' : '${_label(rate)}x'),
                    ],
                  ),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                child: Text(
                  '${_label(_rate)}x',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: '上一集',
            icon: const Icon(Icons.skip_previous),
            onPressed: !_loading && _index > 0 ? () => _go(-1) : null,
          ),
          IconButton(
            tooltip: '下一集',
            icon: const Icon(Icons.skip_next),
            onPressed: !_loading && _index < widget.group.urls.length - 1
                ? () => _go(1)
                : null,
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '播放失败\n$_error',
                    style: const TextStyle(color: Colors.white),
                    textAlign: TextAlign.center,
                    maxLines: 8,
                  ),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _load, child: const Text('重试')),
                ],
              ),
            )
          : Stack(
              children: [
                Positioned.fill(
                  child: Video(
                    controller: _controller,
                    controls: _videoControls,
                  ),
                ),
                if (_loading) const Center(child: CircularProgressIndicator()),
              ],
            ),
    );
  }
}
