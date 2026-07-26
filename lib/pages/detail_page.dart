import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/models.dart';
import '../services/local_library.dart';
import '../services/offline_cache.dart';
import '../services/sources.dart';
import '../services/storage.dart';
import '../widgets/media_card.dart';
import '../widgets/source_image.dart';
import 'manga_reader.dart';
import 'novel_reader.dart';
import 'video_player_page.dart';

class DetailPage extends StatefulWidget {
  final MediaItem item;
  const DetailPage({super.key, required this.item});

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  MediaDetail? _detail;
  String? _error;
  int _groupIndex = 0;
  bool _descExpanded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final detail = await Sources.detail(widget.item);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        final h = Storage.historyOf(widget.item.key);
        if (h != null && h.groupIndex < detail.episodes.length) {
          _groupIndex = h.groupIndex;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  void _openEpisode(int episodeIndex) {
    final detail = _detail!;
    final group = detail.episodes[_groupIndex];
    final item = widget.item;
    Widget page;
    switch (item.type) {
      case MediaType.manga:
        page = MangaReaderPage(
            item: item, group: group, groupIndex: _groupIndex, index: episodeIndex);
      case MediaType.novel:
        page = NovelReaderPage(
            item: item, group: group, groupIndex: _groupIndex, index: episodeIndex);
      case MediaType.anime:
        page = VideoPlayerPage(
            item: item, group: group, groupIndex: _groupIndex, index: episodeIndex);
    }
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  /// Per-episode cache control: download, show progress, or drop the copy.
  Widget _cacheButton(MediaEpisode ep) {
    // Locally imported media is already on disk — caching it would duplicate it.
    if (LocalLibrary.isLocal(widget.item.package)) return const SizedBox.shrink();

    return ListenableBuilder(
      listenable: OfflineCache.instance,
      builder: (context, _) {
        final key = OfflineCache.keyOf(widget.item.package, ep.url);
        final progress = OfflineCache.instance.progressOf(key);

        if (progress != null) {
          return IconButton(
            tooltip: '${progress.label}  ${(progress.fraction * 100).round()}% · 点击取消',
            icon: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                value: progress.fraction == 0 ? null : progress.fraction,
              ),
            ),
            onPressed: () => OfflineCache.instance.cancel(key),
          );
        }

        if (OfflineCache.has(widget.item.package, ep.url)) {
          return IconButton(
            tooltip: '已缓存，点击删除',
            icon: Icon(Icons.download_done,
                size: 20, color: Theme.of(context).colorScheme.primary),
            onPressed: () => OfflineCache.remove(widget.item.package, ep.url),
          );
        }

        return IconButton(
          tooltip: '缓存到本地',
          icon: const Icon(Icons.download_outlined, size: 20),
          onPressed: () async {
            try {
              await OfflineCache.instance.download(widget.item, ep);
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text('缓存失败: $e')));
              }
            }
          },
        );
      },
    );
  }

  /// Queue every episode in the current group, skipping cached ones.
  Future<void> _cacheAll(MediaEpisodeGroup group) async {
    final pending = group.urls
        .where((e) => !OfflineCache.has(widget.item.package, e.url))
        .toList();
    if (pending.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('本组内容都已缓存')));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('缓存全部'),
        content: Text('将缓存 ${pending.length} 项内容，可能占用较多空间和流量。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true), child: const Text('开始')),
        ],
      ),
    );
    if (confirmed != true) return;

    var failed = 0;
    for (final ep in pending) {
      if (!mounted) return;
      try {
        await OfflineCache.instance.download(widget.item, ep);
      } catch (_) {
        failed++;
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(failed == 0
              ? '已缓存 ${pending.length} 项'
              : '完成，${pending.length - failed} 项成功，$failed 项失败')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final detail = _detail;
    final sourceName = Sources.displayName(item.package);

    return Scaffold(
      appBar: AppBar(
        title: Text(detail?.title ?? item.title),
        actions: [
          ValueListenableBuilder(
            valueListenable: Storage.favoritesBox.listenable(),
            builder: (context, box, _) {
              final fav = Storage.isFavorite(item.key);
              return IconButton(
                tooltip: fav ? '从书架移除' : '加入书架',
                icon: Icon(fav ? Icons.favorite : Icons.favorite_border,
                    color: fav ? Colors.redAccent : null),
                onPressed: () => Storage.toggleFavorite(MediaItem(
                  package: item.package,
                  type: item.type,
                  title: detail?.title.isNotEmpty == true ? detail!.title : item.title,
                  url: item.url,
                  cover: detail?.cover.isNotEmpty == true ? detail!.cover : item.cover,
                )),
              );
            },
          ),
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
          : detail == null
              ? const Center(child: CircularProgressIndicator())
              : _buildDetail(detail, sourceName),
    );
  }

  Widget _buildDetail(MediaDetail detail, String sourceName) {
    final history = Storage.historyOf(widget.item.key);
    final group = detail.episodes.isEmpty ? null : detail.episodes[_groupIndex];

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 120,
                    height: 170,
                    child: SourceImage(
                      url: detail.cover.isEmpty ? widget.item.cover : detail.cover,
                      package: widget.item.package,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(detail.title,
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, children: [
                        Chip(
                          label: Text(widget.item.type.label,
                              style: const TextStyle(fontSize: 12, color: Colors.white)),
                          backgroundColor: typeColor(widget.item.type),
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                        ),
                        Chip(
                          label: Text(sourceName, style: const TextStyle(fontSize: 12)),
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                        ),
                      ]),
                      const SizedBox(height: 8),
                      if (group != null)
                        FilledButton.icon(
                          icon: const Icon(Icons.play_arrow),
                          label: Text(history == null
                              ? '开始${widget.item.type == MediaType.anime ? '观看' : '阅读'}'
                              : '继续: ${history.episodeName}'),
                          onPressed: () {
                            var idx = 0;
                            if (history != null &&
                                history.groupIndex == _groupIndex &&
                                history.episodeIndex < group.urls.length) {
                              idx = history.episodeIndex;
                            }
                            _openEpisode(idx);
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (detail.desc.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: InkWell(
                onTap: () => setState(() => _descExpanded = !_descExpanded),
                child: Text(
                  detail.desc,
                  maxLines: _descExpanded ? null : 3,
                  overflow: _descExpanded ? null : TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Text('共 ${group?.urls.length ?? 0} 个章节/剧集',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                if (group != null && !LocalLibrary.isLocal(widget.item.package))
                  TextButton.icon(
                    icon: const Icon(Icons.download_for_offline_outlined, size: 18),
                    label: const Text('缓存全部'),
                    onPressed: () => _cacheAll(group),
                  ),
                if (detail.episodes.length > 1)
                  DropdownButton<int>(
                    value: _groupIndex,
                    items: [
                      for (var i = 0; i < detail.episodes.length; i++)
                        DropdownMenuItem(
                            value: i, child: Text(detail.episodes[i].title)),
                    ],
                    onChanged: (v) => setState(() => _groupIndex = v ?? 0),
                  ),
              ],
            ),
          ),
        ),
        if (group != null)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: SliverList.builder(
              itemCount: group.urls.length,
              itemBuilder: (context, i) {
                final ep = group.urls[i];
                final isLast = history != null &&
                    history.groupIndex == _groupIndex &&
                    history.episodeIndex == i;
                return ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  title: Text(ep.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isLast ? Theme.of(context).colorScheme.primary : null,
                        fontWeight: isLast ? FontWeight.bold : null,
                      )),
                  leading: isLast ? const Icon(Icons.bookmark, size: 18) : null,
                  trailing: _cacheButton(ep),
                  onTap: () => _openEpisode(i),
                );
              },
            ),
          ),
      ],
    );
  }
}
