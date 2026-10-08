import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/models.dart';
import '../services/extension_manager.dart';
import '../services/local_library.dart';
import '../services/sources.dart';
import '../services/storage.dart';
import '../widgets/media_card.dart' show typeColor;
import '../widgets/source_image.dart';
import 'detail_page.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  MediaType? _filter;

  // Legacy records may have no title/cover. Keep them accessible when their
  // source is still installed; visiting the detail page fills in the metadata.
  MediaItem? _itemOf(HistoryRecord record) {
    if (record.item != null) return record.item;
    final separator = record.key.indexOf('|');
    if (separator <= 0 || separator == record.key.length - 1) return null;
    final package = record.key.substring(0, separator);
    final type = ExtensionManager.instance.byPackage(package)?.meta.type;
    if (type == null) return null;
    return MediaItem(
      package: package,
      type: type,
      title: '旧阅读记录',
      url: record.key.substring(separator + 1),
    );
  }

  String _dayLabel(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final day = DateTime(date.year, date.month, date.day);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (day == today) return '今天';
    if (day == DateTime(now.year, now.month, now.day - 1)) return '昨天';
    return '${date.year}年${date.month}月${date.day}日';
  }

  String _timeLabel(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _remove(HistoryRecord record) async {
    await Storage.removeHistory(record.key);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: const Text('已删除历史记录和阅读进度'),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () {
            // A new visit may already have created a newer reading position.
            if (!Storage.historyBox.containsKey(record.key)) {
              Storage.saveHistory(record);
            }
          },
        ),
      ),
    );
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空历史记录？'),
        content: const Text('将清空全部浏览记录和阅读进度，已收藏的作品仍保留在书架。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      if (mounted) ScaffoldMessenger.of(context).clearSnackBars();
      await Storage.clearHistory();
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: Storage.historyBox.listenable(),
    builder: (context, _, _) {
      final all = Storage.history();
      final records = _filter == null
          ? all
          : all.where((record) => _itemOf(record)?.type == _filter).toList();
      return Scaffold(
        appBar: AppBar(
          title: const Text('历史记录'),
          actions: [
            IconButton(
              tooltip: '清空历史记录',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: all.isEmpty ? null : _clear,
            ),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('全部'),
                    selected: _filter == null,
                    onSelected: (_) => setState(() => _filter = null),
                  ),
                  for (final type in MediaType.values)
                    ChoiceChip(
                      label: Text(type.label),
                      selected: _filter == type,
                      onSelected: (_) => setState(() => _filter = type),
                    ),
                ],
              ),
            ),
            Expanded(
              child: records.isEmpty
                  ? Center(
                      child: Text(
                        _filter == null
                            ? '还没有历史记录\n浏览或阅读过的作品会自动保存在这里'
                            : '还没有${_filter!.label}历史记录',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 16),
                      itemCount: records.length,
                      itemBuilder: (context, index) {
                        final record = records[index];
                        final item = _itemOf(record);
                        final day = _dayLabel(record.timestamp);
                        final showDay =
                            index == 0 ||
                            day != _dayLabel(records[index - 1].timestamp);
                        final package =
                            item?.package ?? record.key.split('|').first;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (showDay)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  16,
                                  16,
                                  8,
                                ),
                                child: Text(
                                  day,
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                              ),
                            ListTile(
                              key: ValueKey(record.key),
                              leading: SizedBox(
                                width: 56,
                                height: 80,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: SourceImage(
                                    url: item?.cover ?? '',
                                    package: package,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              ),
                              title: Text(
                                item?.title.isNotEmpty == true
                                    ? item!.title
                                    : '旧阅读记录',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${item == null ? (LocalLibrary.isLocal(package) ? '本地' : '扩展未安装') : item.type.label}'
                                    ' · ${Sources.displayName(package)}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: item == null
                                          ? null
                                          : typeColor(item.type),
                                    ),
                                  ),
                                  Text(
                                    record.hasProgress
                                        ? '${item?.type == MediaType.anime ? '看到' : '读到'}：${record.episodeName}'
                                        : '仅浏览，尚未开始阅读',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(_timeLabel(record.timestamp)),
                                ],
                              ),
                              trailing: IconButton(
                                tooltip: '删除记录',
                                icon: const Icon(Icons.close, size: 20),
                                onPressed: () => _remove(record),
                              ),
                              onTap: () {
                                if (item == null) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        LocalLibrary.isLocal(package)
                                            ? '请重新导入这条旧记录对应的本地文件，再打开作品'
                                            : '请先安装这条记录对应的扩展，再打开作品',
                                      ),
                                    ),
                                  );
                                  return;
                                }
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => DetailPage(item: item),
                                  ),
                                );
                              },
                            ),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      );
    },
  );
}
