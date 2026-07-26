import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/models.dart';
import '../services/player_config.dart';
import '../services/sources.dart';
import '../services/storage.dart';

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

  MediaEpisode get _episode => widget.group.urls[_index];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await Sources.watch(widget.item, _episode.url);
      final watch = AnimeWatch.fromJson(raw);
      if (!mounted) return;

      await configurePlayerFor(_player, widget.item.package, watch);
      await _player.open(await buildMedia(widget.item.package, watch));
      await Storage.saveHistory(HistoryRecord(
        key: widget.item.key,
        episodeUrl: _episode.url,
        episodeName: _episode.name,
        groupIndex: widget.groupIndex,
        episodeIndex: _index,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ));
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
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
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${widget.item.title} · ${_episode.name}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '上一集',
            icon: const Icon(Icons.skip_previous),
            onPressed: _index > 0 ? () => _go(-1) : null,
          ),
          IconButton(
            tooltip: '下一集',
            icon: const Icon(Icons.skip_next),
            onPressed: _index < widget.group.urls.length - 1 ? () => _go(1) : null,
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('播放失败\n$_error',
                      style: const TextStyle(color: Colors.white),
                      textAlign: TextAlign.center,
                      maxLines: 8),
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
                    controls: AdaptiveVideoControls,
                  ),
                ),
                if (_loading)
                  const Center(child: CircularProgressIndicator()),
              ],
            ),
    );
  }
}
