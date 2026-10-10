import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/extension_manager.dart';
import '../services/storage.dart';
import '../widgets/media_card.dart';
import 'extension_repository_page.dart';

class ExtensionsPage extends StatelessWidget {
  const ExtensionsPage({super.key});

  Future<void> _installFromUrl(BuildContext context) async {
    final ctrl = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('从 URL 安装扩展'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            hintText: 'https://.../extension.js',
            helperText: '支持 Miru 格式扩展脚本的直链（如 Miru 仓库 raw 链接）',
          ),
        ),
        actions: [
          IconButton(
            tooltip: '插件仓库',
            icon: const Icon(Icons.extension_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const ExtensionRepositoryPage(),
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text.trim()),
            child: const Text('安装'),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty || !context.mounted) return;
    try {
      final meta = await ExtensionManager.instance.installFromUrl(url);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已安装扩展: ${meta.name}')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('安装失败: $e')));
      }
    }
  }

  Future<void> _installFromScript(BuildContext context) async {
    final ctrl = TextEditingController();
    final script = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('粘贴扩展脚本'),
        content: SizedBox(
          width: 500,
          child: TextField(
            controller: ctrl,
            maxLines: 12,
            decoration: const InputDecoration(
              hintText: '// ==MiruExtension==\n// @name ...\n...',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text),
            child: const Text('安装'),
          ),
        ],
      ),
    );
    if (script == null || script.trim().isEmpty || !context.mounted) return;
    try {
      final meta = await ExtensionManager.instance.installFromScript(script);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已安装扩展: ${meta.name}')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('安装失败: $e')));
      }
    }
  }

  Future<void> _editSettings(BuildContext context, ExtensionMeta meta) async {
    final schemas = Storage.extSettingSchemas(meta.package);
    if (schemas.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('该扩展没有可配置项')));
      return;
    }
    final controllers = {
      for (final s in schemas)
        s['key'].toString(): TextEditingController(
          text: (Storage.extSetting(meta.package, s['key'].toString()) ?? '')
              .toString(),
        ),
    };

    final save = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${meta.name} 设置'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final s in schemas)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TextField(
                    controller: controllers[s['key'].toString()],
                    obscureText: s['type'] == 'password',
                    decoration: InputDecoration(
                      labelText: s['title']?.toString(),
                      helperText: s['description']?.toString(),
                      helperMaxLines: 2,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (save == true) {
      for (final entry in controllers.entries) {
        await Storage.setExtSetting(meta.package, entry.key, entry.value.text);
      }
      // Credentials feed a cached session token; drop it so the next call
      // signs in again with the new values.
      await Storage.setExtSetting(meta.package, '__token', '');
      await ExtensionManager.instance.reload(meta.package);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('设置已保存')));
      }
    }
    for (final c in controllers.values) {
      c.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final manager = ExtensionManager.instance;
    return Scaffold(
      appBar: AppBar(
        title: const Text('扩展'),
        actions: [
          IconButton(
            tooltip: '从 URL 安装',
            icon: const Icon(Icons.link),
            onPressed: () => _installFromUrl(context),
          ),
          IconButton(
            tooltip: '粘贴脚本安装',
            icon: const Icon(Icons.paste),
            onPressed: () => _installFromScript(context),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: manager,
        builder: (context, _) {
          final list = manager.all;
          return ListView.builder(
            itemCount: list.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) {
                return Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '插件独立发布，填写仓库链接后可安装和更新；⚠ 表示插件加载失败。',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      TextButton.icon(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const ExtensionRepositoryPage(),
                          ),
                        ),
                        icon: const Icon(Icons.extension_outlined),
                        label: const Text('打开插件仓库'),
                      ),
                    ],
                  ),
                );
              }
              final service = list[i - 1];
              final meta = service.meta;
              final disabled = Storage.isExtensionDisabled(meta.package);
              final error = manager.loadErrors[meta.package];
              final userInstalled = Storage.isInstalledByUser(meta.package);
              return ListTile(
                leading: SizedBox(
                  width: 40,
                  height: 40,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: meta.icon.isEmpty
                        ? Icon(Icons.extension, color: typeColor(meta.type))
                        : CachedNetworkImage(
                            imageUrl: meta.icon,
                            errorWidget: (c, u, e) => Icon(
                              Icons.extension,
                              color: typeColor(meta.type),
                            ),
                          ),
                  ),
                ),
                title: Row(
                  children: [
                    if (manager.hasUpdate(meta.package))
                      IconButton(
                        tooltip: '插件有更新',
                        icon: const Icon(Icons.system_update_alt),
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const ExtensionRepositoryPage(),
                          ),
                        ),
                      ),
                    Flexible(
                      child: Text(meta.name, overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: typeColor(meta.type).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        meta.type.label,
                        style: TextStyle(
                          fontSize: 10,
                          color: typeColor(meta.type),
                        ),
                      ),
                    ),
                    if (error != null && !disabled)
                      const Padding(
                        padding: EdgeInsets.only(left: 6),
                        child: Tooltip(
                          message: '加载失败',
                          child: Text('⚠', style: TextStyle(fontSize: 14)),
                        ),
                      ),
                  ],
                ),
                subtitle: Text(
                  error != null && !disabled
                      ? error
                      : '${meta.package} ${meta.version} · ${meta.webSite}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: error != null && !disabled ? Colors.redAccent : null,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (Storage.extSettingSchemas(meta.package).isNotEmpty)
                      IconButton(
                        tooltip: '扩展设置（帐号等）',
                        icon: const Icon(Icons.tune),
                        onPressed: () => _editSettings(context, meta),
                      ),
                    Switch(
                      value: !disabled,
                      onChanged: manager.isInstalling(meta.package)
                          ? null
                          : (v) => manager.setDisabled(meta.package, !v),
                    ),
                    if (userInstalled)
                      IconButton(
                        tooltip: '卸载',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: manager.isInstalling(meta.package)
                            ? null
                            : () => manager.uninstall(meta.package),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
