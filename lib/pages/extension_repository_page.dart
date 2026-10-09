import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/extension_manager.dart';
import '../services/extension_repository.dart';

class ExtensionRepositoryPage extends StatefulWidget {
  const ExtensionRepositoryPage({super.key});
  @override
  State<ExtensionRepositoryPage> createState() =>
      _ExtensionRepositoryPageState();
}

class _ExtensionRepositoryPageState extends State<ExtensionRepositoryPage> {
  final manager = ExtensionManager.instance;
  String query = '';
  MediaType? type;
  final Set<String> pending = {};
  bool updating = false;
  @override
  void initState() {
    super.initState();
    manager.refreshRepository();
  }

  void message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> install(RepositoryExtension entry) async {
    setState(() => pending.add(entry.package));
    try {
      await manager.installFromRepository(entry);
      message('${entry.name} 已安装或更新');
    } catch (error) {
      message(
        error is FormatException
            ? error.message
            : '${entry.name} 安装失败，原插件保留。请检查网络或刷新仓库。',
      );
    } finally {
      if (mounted) setState(() => pending.remove(entry.package));
    }
  }

  Future<void> update({bool restore = false}) async {
    setState(() => updating = true);
    try {
      final failures = await manager.updateInstalled(restoreLegacy: restore);
      message(
        failures.isEmpty
            ? (restore ? '旧版插件已恢复，原有设置保留' : '已安装插件已检查并更新')
            : '部分插件未完成：${failures.keys.join('、')}，可以单独重试',
      );
    } catch (_) {
      message('无法更新插件仓库，请检查网络后重试。');
    } finally {
      if (mounted) setState(() => updating = false);
    }
  }

  Future<void> editRepository() async {
    var address = manager.repositoryUrl;
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('插件仓库地址'),
        content: TextFormField(
          initialValue: address,
          maxLines: 3,
          onChanged: (value) => address = value,
          decoration: const InputDecoration(
            helperText: '填写可信仓库的 HTTPS index.json 地址',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, defaultExtensionRepository),
            child: const Text('使用默认仓库'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, address.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (value == null || !mounted) return;
    try {
      await manager.setRepository(value);
      message('插件仓库已更新');
    } catch (_) {
      message('仓库地址无效或暂时无法连接，原仓库保留。');
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: manager,
    builder: (context, _) {
      final entries = (manager.catalog?.extensions ?? <RepositoryExtension>[])
          .where(
            (entry) =>
                (type == null || entry.type == type) &&
                '${entry.name} ${entry.package} ${entry.lang}'
                    .toLowerCase()
                    .contains(query.toLowerCase()),
          )
          .toList();
      final busy = updating || pending.isNotEmpty;
      return Scaffold(
        appBar: AppBar(
          title: const Text('插件仓库'),
          actions: [
            IconButton(
              tooltip: '仓库地址',
              onPressed: busy || manager.checkingRepository
                  ? null
                  : editRepository,
              icon: const Icon(Icons.link),
            ),
            IconButton(
              tooltip: '刷新仓库',
              onPressed: manager.checkingRepository || busy
                  ? null
                  : manager.refreshRepository,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: Column(
          children: [
            if (manager.checkingRepository || updating)
              const LinearProgressIndicator(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('插件独立发布，更新不需要重新安装应用。下载后保存在本机，离线仍可使用。'),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      FilledButton.tonal(
                        onPressed: busy || manager.checkingRepository
                            ? null
                            : () => update(),
                        child: const Text('更新已安装插件'),
                      ),
                      OutlinedButton(
                        onPressed: busy || manager.checkingRepository
                            ? null
                            : () => update(restore: true),
                        child: const Text('恢复旧版插件'),
                      ),
                    ],
                  ),
                  if (manager.repositoryError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        manager.repositoryError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: '搜索插件名称或语言',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) => setState(() => query = value),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('全部'),
                        selected: type == null,
                        onSelected: (_) => setState(() => type = null),
                      ),
                      for (final kind in MediaType.values)
                        ChoiceChip(
                          label: Text(kind.label),
                          selected: type == kind,
                          onSelected: (_) => setState(() => type = kind),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: entries.isEmpty
                  ? Center(
                      child: Text(
                        manager.checkingRepository
                            ? '正在读取插件目录…'
                            : '暂无插件，请刷新仓库或调整筛选。',
                      ),
                    )
                  : ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        final installed = manager.byPackage(entry.package);
                        final needsUpdate = manager.hasUpdate(entry.package);
                        final compatible = entry.supports(manager.appVersion);
                        final loading =
                            pending.contains(entry.package) ||
                            manager.isInstalling(entry.package);
                        return ListTile(
                          leading: Icon(
                            entry.type == MediaType.novel
                                ? Icons.menu_book
                                : entry.type == MediaType.manga
                                ? Icons.collections_bookmark
                                : Icons.play_circle_outline,
                          ),
                          title: Text(entry.name),
                          subtitle: Text(
                            '${entry.type.label} · ${entry.lang} · ${entry.version}${compatible ? '' : '\n需要应用 ${entry.minAppVersion} 或更新版本'}',
                          ),
                          trailing: loading
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : FilledButton.tonal(
                                  onPressed:
                                      busy ||
                                          !compatible ||
                                          (installed != null && !needsUpdate)
                                      ? null
                                      : () => install(entry),
                                  child: Text(
                                    installed == null
                                        ? '安装'
                                        : needsUpdate
                                        ? '更新'
                                        : '已安装',
                                  ),
                                ),
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
