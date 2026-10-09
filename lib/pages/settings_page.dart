import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/offline_cache.dart';
import '../services/account_service.dart';
import 'account_page.dart';
import 'library_transfer_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

  @override
  void initState() {
    super.initState();
    AccountService.instance.initialize();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('账号', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ListenableBuilder(
            listenable: AccountService.instance,
            builder: (context, _) => Card(
              child: ListTile(
                leading: const Icon(Icons.cloud_sync_outlined),
                title: const Text('账号与同步'),
                subtitle: Text(
                  AccountService.instance.session?.username ??
                      '用激活码注册，手动同步书架和历史',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const AccountPage())),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text('数据迁移', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.import_export),
              title: const Text('导入与导出'),
              subtitle: const Text('通过 JSON 文件迁移书架、浏览历史和阅读进度'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LibraryTransferPage()),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text('离线缓存', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ListenableBuilder(
            listenable: OfflineCache.instance,
            builder: (context, _) {
              final entries = OfflineCache.allEntries();
              final bytes = entries.fold<int>(
                0,
                (sum, e) => sum + ((e['bytes'] as num?)?.toInt() ?? 0),
              );
              final byType = <String, int>{};
              for (final e in entries) {
                final t = (e['type'] ?? '?').toString();
                byType[t] = (byType[t] ?? 0) + 1;
              }
              String label(String t) => switch (t) {
                'manga' => '漫画',
                'novel' => '小说',
                'anime' => '动画',
                _ => t,
              };

              return Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.sd_storage_outlined),
                      title: Text(
                        '已缓存 ${entries.length} 项 · '
                        '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB',
                      ),
                      subtitle: Text(
                        entries.isEmpty
                            ? '在作品详情页点章节右侧的下载图标即可缓存'
                            : byType.entries
                                  .map((e) => '${label(e.key)} ${e.value}')
                                  .join(' · '),
                      ),
                    ),
                    if (entries.isNotEmpty)
                      Align(
                        alignment: Alignment.centerRight,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 8, bottom: 8),
                          child: TextButton.icon(
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('清空缓存'),
                            onPressed: () async {
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (c) => AlertDialog(
                                  title: const Text('清空离线缓存'),
                                  content: Text(
                                    '将删除全部 ${entries.length} 项缓存内容，'
                                    '释放约 ${(bytes / 1024 / 1024).toStringAsFixed(1)} MB。'
                                    '本地导入的书籍不受影响。',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(c),
                                      child: const Text('取消'),
                                    ),
                                    FilledButton(
                                      onPressed: () => Navigator.pop(c, true),
                                      child: const Text('清空'),
                                    ),
                                  ],
                                ),
                              );
                              if (ok == true) await OfflineCache.clearAll();
                            },
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 24),
          Text('关于', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FutureBuilder<PackageInfo>(
                    future: _packageInfo,
                    builder: (context, snapshot) => Text(
                      snapshot.hasData
                          ? 'FusionReader 聚阅 v${snapshot.data!.version} (${snapshot.data!.buildNumber})'
                          : 'FusionReader 聚阅',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '漫画 / 小说 / 动画 三合一聚合阅读器\n'
                    '· 统一书架：三种类型内容放在同一书架\n'
                    '· Miru 兼容的 JS 扩展系统，可从 URL 安装新源\n'
                    '· 全平台支持：Windows / Android / iOS / macOS / Linux\n\n'
                    '参考 Miru Project 设计，扩展格式与其兼容。',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
