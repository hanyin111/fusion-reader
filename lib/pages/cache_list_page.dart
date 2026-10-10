import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/cache_download_queue.dart';
import '../services/offline_cache.dart';
import 'detail_page.dart';

class CacheListPage extends StatelessWidget {
  const CacheListPage({super.key});

  String _state(CacheTaskState state) => switch (state) {
    CacheTaskState.queued => '等待缓存',
    CacheTaskState.downloading => '正在缓存',
    CacheTaskState.cancelling => '正在取消',
    CacheTaskState.completed => '已完成',
    CacheTaskState.failed => '缓存失败',
    CacheTaskState.cancelled => '已取消',
  };

  void _open(BuildContext context, MediaItem item) => Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => DetailPage(item: item)));

  Future<void> _remove(BuildContext context, Map entry) async {
    try {
      await OfflineCache.remove(
        entry['package'].toString(),
        entry['episodeUrl'].toString(),
      );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('删除失败：$error')));
      }
    }
  }

  Widget _tasks(BuildContext context) {
    final cache = OfflineCache.instance;
    final tasks = cache.queue.tasks;
    if (tasks.isEmpty) return const Center(child: Text('暂无缓存任务'));
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: tasks.length,
      itemBuilder: (context, index) {
        final task = tasks[index];
        final progress = cache.progressOf(task.key);
        return Card(
          child: Column(
            children: [
              ListTile(
                title: Text(
                  task.item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${task.episode.name} · ${_state(task.state)}'
                  '${task.error == null ? '' : '\n${task.error}'}',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => _open(context, task.item),
                trailing: task.isActive
                    ? IconButton(
                        tooltip: '取消缓存',
                        icon: const Icon(Icons.close),
                        onPressed: task.state == CacheTaskState.cancelling
                            ? null
                            : () => cache.cancel(task.key),
                      )
                    : task.state == CacheTaskState.failed ||
                          task.state == CacheTaskState.cancelled
                    ? IconButton(
                        tooltip: '重试缓存',
                        icon: const Icon(Icons.refresh),
                        onPressed: () => cache.queue.retry(task.key),
                      )
                    : const Icon(Icons.download_done),
              ),
              if (task.state == CacheTaskState.downloading ||
                  task.state == CacheTaskState.cancelling)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        progress?.label ?? '准备中',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(
                        value: progress == null || progress.fraction == 0
                            ? null
                            : progress.fraction.clamp(0, 1),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _cached(BuildContext context) {
    final works = <String, List<Map>>{};
    for (final entry in OfflineCache.allEntries()) {
      works.putIfAbsent(entry['itemKey'].toString(), () => []).add(entry);
    }
    if (works.isEmpty) return const Center(child: Text('暂无已缓存内容'));
    final groups = works.values.toList();
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: groups.length,
      itemBuilder: (context, index) {
        final entries = groups[index];
        final first = entries.first;
        final item = MediaItem(
          package: first['package'].toString(),
          type: MediaType.fromString(first['type'].toString()),
          title: (first['itemTitle'] ?? '已缓存作品').toString(),
          url: (first['itemUrl'] ?? '').toString(),
          cover: (first['itemCover'] ?? '').toString(),
        );
        final bytes = entries.fold<int>(
          0,
          (sum, entry) => sum + ((entry['bytes'] as num?)?.toInt() ?? 0),
        );
        return Card(
          child: ExpansionTile(
            title: Text(item.title),
            subtitle: Text(
              '${entries.length} 个章节 · ${(bytes / 1024 / 1024).toStringAsFixed(1)} MB',
            ),
            children: [
              ListTile(
                leading: const Icon(Icons.menu_book),
                title: const Text('打开作品'),
                onTap: () => _open(context, item),
              ),
              for (final entry in entries)
                ListTile(
                  dense: true,
                  title: Text((entry['episodeName'] ?? '章节').toString()),
                  trailing: IconButton(
                    tooltip: '删除缓存',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _remove(context, entry),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('缓存列表'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'cancel') {
                OfflineCache.instance.queue.cancelAll();
              } else {
                OfflineCache.instance.queue.clearFinished();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'cancel', child: Text('取消全部下载')),
              PopupMenuItem(value: 'clear', child: Text('清除已结束的任务记录')),
            ],
          ),
        ],
        bottom: const TabBar(
          tabs: [
            Tab(text: '下载任务'),
            Tab(text: '已缓存'),
          ],
        ),
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('离开目录页后会继续缓存，请保持应用运行。'),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: OfflineCache.instance,
              builder: (context, _) =>
                  TabBarView(children: [_tasks(context), _cached(context)]),
            ),
          ),
        ],
      ),
    ),
  );
}
