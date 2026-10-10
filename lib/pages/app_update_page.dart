import 'package:flutter/material.dart';

import '../models/app_update.dart';
import '../services/app_update_controller.dart';

class AppUpdatePage extends StatefulWidget {
  final AppUpdateController? controller;
  const AppUpdatePage({super.key, this.controller});
  @override
  State<AppUpdatePage> createState() => _AppUpdatePageState();
}

class _AppUpdatePageState extends State<AppUpdatePage> {
  late final AppUpdateController _controller =
      widget.controller ?? AppUpdateController();
  @override
  void initState() {
    super.initState();
    _controller.check();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _install() async {
    if (_controller.device?.platform == UpdatePlatform.windows) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('安装更新'),
          content: const Text('聚阅将关闭并安装更新，随后自动重新打开。书架、历史和插件会保留。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('安装并重启'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    await _controller.install();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('检查更新')),
    body: ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final release = _controller.release;
        final phase = _controller.phase;
        final downloading = const [
          AppUpdatePhase.downloading,
          AppUpdatePhase.verifying,
        ].contains(phase);
        final available =
            phase == AppUpdatePhase.available || phase == AppUpdatePhase.ready;
        final status = switch (phase) {
          AppUpdatePhase.checking => '正在检查新版本…',
          AppUpdatePhase.current => '当前已是最新版本',
          AppUpdatePhase.available => '发现新版本 v${release?.version}',
          AppUpdatePhase.downloading => '正在下载更新…',
          AppUpdatePhase.verifying => '下载完成，正在校验和准备安装…',
          AppUpdatePhase.ready => '更新包已准备好',
          AppUpdatePhase.installing => '正在启动安装…',
          AppUpdatePhase.failed => '检查更新失败',
        };
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(status, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            if (_controller.currentVersion.isNotEmpty)
              Text('当前版本 v${_controller.currentVersion}'),
            if (release != null) Text('最新正式版 v${release.version}'),
            if (phase == AppUpdatePhase.checking ||
                phase == AppUpdatePhase.installing)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: LinearProgressIndicator(),
              ),
            if (downloading) ...[
              const SizedBox(height: 20),
              LinearProgressIndicator(
                value: _controller.total == 0
                    ? null
                    : _controller.received / _controller.total,
              ),
              const SizedBox(height: 8),
              Text(
                '${(_controller.received / 1048576).toStringAsFixed(1)} / ${(_controller.total / 1048576).toStringAsFixed(1)} MB',
              ),
              TextButton(
                onPressed: _controller.cancelDownload,
                child: const Text('取消下载'),
              ),
            ],
            if (_controller.error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  _controller.error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (_controller.message.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(_controller.message),
              ),
            if (available) ...[
              const SizedBox(height: 20),
              if (_controller.canInstall && release?.asset != null) ...[
                Text(
                  '更新包 ${(release!.asset!.size / 1048576).toStringAsFixed(1)} MB',
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: phase == AppUpdatePhase.ready
                      ? _install
                      : _controller.download,
                  icon: Icon(
                    phase == AppUpdatePhase.ready
                        ? Icons.system_update
                        : Icons.download,
                  ),
                  label: Text(
                    phase == AppUpdatePhase.ready
                        ? _controller.device?.platform == UpdatePlatform.windows
                              ? '安装并重启'
                              : '安装更新'
                        : '下载更新',
                  ),
                ),
              ] else if (_controller.canInstall)
                const Text('当前平台的安装包或文件校验信息尚未就绪，请稍后再次检查。')
              else if (_controller.device?.platform == UpdatePlatform.ios)
                const Text('iOS 版请下载 IPA，再通过原来的签名或侧载工具更新安装。')
              else
                const Text('当前平台请通过发布页下载更新。'),
            ],
            if (!_controller.busy) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _controller.check,
                icon: const Icon(Icons.refresh),
                label: const Text('重新检查'),
              ),
              if (release != null)
                TextButton(
                  onPressed: _controller.openRelease,
                  child: const Text('打开发布页'),
                ),
            ],
            if (release != null && release.notes.trim().isNotEmpty) ...[
              const SizedBox(height: 24),
              Text('更新内容', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              SelectableText(release.notes),
            ],
          ],
        );
      },
    ),
  );
}
