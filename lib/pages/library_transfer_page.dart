import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../services/library_backup.dart';
import '../services/library_transfer_files.dart';
import '../services/storage.dart';

class LibraryTransferPage extends StatefulWidget {
  final LibraryTransferFiles? files;
  const LibraryTransferPage({super.key, this.files});

  @override
  State<LibraryTransferPage> createState() => _LibraryTransferPageState();
}

class _LibraryTransferPageState extends State<LibraryTransferPage> {
  late final _files = widget.files ?? LibraryTransferFiles();
  bool _busy = false;
  bool _previewing = false;
  String? _message;
  bool _failed = false;

  Future<void> _run(Future<String?> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
      _failed = false;
    });
    try {
      final message = await action();
      if (mounted) setState(() => _message = message);
    } on FormatException catch (error) {
      if (mounted) {
        setState(() {
          _failed = true;
          _message = error.message;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _failed = true;
          _message = '操作失败，请检查文件位置和可用空间后重试。\n$error';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _previewing = false;
        });
      }
    }
  }

  Future<String?> _export() async {
    final backup = LibraryBackup.capture();
    final path = await _files.save(backup);
    if (path == null) return null;
    return '已导出 ${backup.favorites.length} 项收藏、${backup.history.length} 条历史。\n'
        '文件已保存到你选择的位置。';
  }

  Future<String?> _import() async {
    final picked = await _files.pick();
    if (picked == null || !mounted) return null;
    final backup = picked.backup;
    final knownPackages = {...Storage.installedScripts().keys};
    final missing = backup.packages.difference(knownPackages);
    final date = backup.exportedAt.toLocal();
    setState(() => _previewing = true);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认导入'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(picked.name),
              const SizedBox(height: 12),
              Text(
                '导出时间：${date.year}-${date.month.toString().padLeft(2, '0')}-'
                '${date.day.toString().padLeft(2, '0')} '
                '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}',
              ),
              Text('书架收藏：${backup.favorites.length} 项'),
              Text('浏览历史：${backup.history.length} 条（含阅读进度）'),
              const SizedBox(height: 12),
              const Text(
                '合并到当前书架与历史，重复作品自动去重，'
                '阅读进度按记录时间保留较新的一份。只浏览过作品的记录不会清除已保存的章节进度。',
              ),
              if (missing.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('有 ${missing.length} 个来源需要安装对应插件后才能阅读。收藏和历史会先保留。'),
              ],
              if (backup.excludedLocalFavorites + backup.excludedLocalHistory >
                  0) ...[
                const SizedBox(height: 12),
                const Text('备份中的本地书籍记录已跳过，请在本机另行导入原文件。'),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('合并导入'),
          ),
        ],
      ),
    );
    if (!mounted) return null;
    setState(() => _previewing = false);
    if (confirmed != true) return null;
    final result = await backup.merge();
    return '导入完成。${result.summary}';
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('导入与导出')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '把书架、浏览历史和阅读进度保存为 JSON 文件，'
            '再在另一台设备导入，即可继续阅读。',
          ),
          const SizedBox(height: 16),
          ListenableBuilder(
            listenable: Listenable.merge([
              Storage.favoritesBox.listenable(),
              Storage.historyBox.listenable(),
            ]),
            builder: (context, _) {
              final backup = LibraryBackup.capture();
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '当前可导出',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${backup.favorites.length} 项书架收藏 · ${backup.history.length} 条浏览历史',
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _busy ? null : () => _run(_export),
                        icon: const Icon(Icons.file_upload_outlined),
                        label: const Text('导出 JSON'),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '从其他设备导入',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '选择导出的 JSON 文件，查看内容数量后合并。'
                    '现有收藏和历史会保留，重复导入不会增加重复条目。',
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _run(_import),
                    icon: const Icon(Icons.file_download_outlined),
                    label: const Text('导入 JSON'),
                  ),
                ],
              ),
            ),
          ),
          if (_busy && !_previewing) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
          ],
          if (_message != null) ...[
            const SizedBox(height: 16),
            Card(
              color: _failed
                  ? Theme.of(context).colorScheme.errorContainer
                  : Theme.of(context).colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_message!),
              ),
            ),
          ],
          const SizedBox(height: 20),
          const Text(
            '支持漫画、小说和动画的网络作品。'
            '本地书籍和离线下载内容需要另行迁移；自装插件请在新设备安装。',
          ),
        ],
      ),
    ),
  );
}
