import 'package:flutter/material.dart';

import '../services/network.dart';
import '../services/storage.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _proxyCtrl =
      TextEditingController(text: Storage.proxy);

  @override
  void dispose() {
    _proxyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('网络', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _proxyCtrl,
            decoration: InputDecoration(
              labelText: 'HTTP 代理 (host:port)',
              hintText: '例如 127.0.0.1:7890，留空则读取系统环境变量',
              helperText: '当前生效: ${Network.resolvedProxy().isEmpty ? "无代理（直连）" : Network.resolvedProxy()}\n'
                  '国内站点（樱花动漫、AGE等）走代理会被拒，请在「扩展」页把它们设为「强制直连」',
              helperMaxLines: 3,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.save),
                tooltip: '保存',
                onPressed: () async {
                  await Storage.setProxy(_proxyCtrl.text.trim());
                  Network.reload();
                  if (context.mounted) {
                    setState(() {});
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('代理设置已保存并生效')));
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text('关于', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('FusionReader 聚阅 v1.0.0',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  SizedBox(height: 8),
                  Text('漫画 / 小说 / 动画 三合一聚合阅读器\n'
                      '· 统一书架：三种类型内容放在同一书架\n'
                      '· Miru 兼容的 JS 扩展系统，可从 URL 安装新源\n'
                      '· 全平台支持：Windows / Android / iOS / macOS / Linux\n\n'
                      '参考 Miru Project 设计，扩展格式与其兼容。'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
