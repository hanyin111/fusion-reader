import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/sources.dart';
import '../services/storage.dart';
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
  double _fontSize =
      (Storage.setting('novelFontSize', defaultValue: 18.0) as num).toDouble();

  MediaEpisode get _episode => widget.group.urls[_index];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _watch = null;
      _error = null;
    });
    try {
      final raw = await Sources.watchCached(widget.item, _episode.url);
      if (!mounted) return;
      setState(() => _watch = NovelWatch.fromJson(raw));
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

  /// Illustrations travel the same route (and carry the same referer headers)
  /// as the chapter they came from, otherwise the site rejects them.
  Widget _illustration(String url, NovelWatch watch) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
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

  void _changeFont(double delta) {
    setState(() => _fontSize = (_fontSize + delta).clamp(12.0, 32.0));
    Storage.setSetting('novelFontSize', _fontSize);
  }

  @override
  Widget build(BuildContext context) {
    final watch = _watch;
    return Scaffold(
      appBar: AppBar(
        title: Text(_episode.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
              tooltip: '减小字号',
              icon: const Icon(Icons.text_decrease),
              onPressed: () => _changeFont(-1)),
          IconButton(
              tooltip: '增大字号',
              icon: const Icon(Icons.text_increase),
              onPressed: () => _changeFont(1)),
        ],
      ),
      body: _error != null
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('加载失败\n$_error', textAlign: TextAlign.center, maxLines: 8),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _load, child: const Text('重试')),
                ],
              ),
            )
          : watch == null
              ? const Center(child: CircularProgressIndicator())
              : SelectionArea(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    itemCount: watch.blocks.length + 1,
                    itemBuilder: (context, i) {
                      if (i == 0) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Text(
                            watch.subtitle.isNotEmpty ? watch.subtitle : _episode.name,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                        );
                      }
                      final block = watch.blocks[i - 1];
                      if (block.isImage) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: _illustration(block.imageUrl, watch),
                        );
                      }
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          block.text,
                          style: TextStyle(fontSize: _fontSize, height: 1.7),
                        ),
                      );
                    },
                  ),
                ),
      bottomNavigationBar: BottomAppBar(
        height: 56,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton.icon(
              icon: const Icon(Icons.chevron_left),
              label: const Text('上一章'),
              onPressed: _index > 0 ? () => _go(-1) : null,
            ),
            Text('${_index + 1} / ${widget.group.urls.length}'),
            TextButton.icon(
              icon: const Icon(Icons.chevron_right),
              label: const Text('下一章'),
              iconAlignment: IconAlignment.end,
              onPressed: _index < widget.group.urls.length - 1 ? () => _go(1) : null,
            ),
          ],
        ),
      ),
    );
  }
}
