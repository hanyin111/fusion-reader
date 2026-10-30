import 'package:flutter/material.dart';

import '../services/network_proxy_settings.dart';
import '../services/proxy_resolver.dart';

class NetworkProxyPage extends StatefulWidget {
  const NetworkProxyPage({super.key});

  @override
  State<NetworkProxyPage> createState() => _NetworkProxyPageState();
}

class _NetworkProxyPageState extends State<NetworkProxyPage> {
  final _form = GlobalKey<FormState>();
  late final _address = TextEditingController(
    text: NetworkProxySettings.address,
  );
  late bool _enabled = NetworkProxySettings.address.isNotEmpty;
  bool _busy = false;
  String? _result;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _run({required bool save}) async {
    if (_enabled && !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      if (save) {
        await NetworkProxySettings.save(_enabled ? _address.text : '');
      } else {
        await NetworkProxySettings.test(_address.text);
      }
      if (!mounted) return;
      setState(
        () => _result = save ? '已应用，请返回并重试加载。' : '代理连接正常，已完成 HTTPS 连接测试。',
      );
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _result = save ? '保存失败，请重试。' : '代理连接失败，请确认地址、端口和代理软件的接入设置。',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('网络代理')),
    body: Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('默认跟随系统网络。系统未提供 HTTP 代理入口时，可以手动填写。'),
          const SizedBox(height: 16),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('使用手动 HTTP 代理'),
            value: _enabled,
            onChanged: _busy
                ? null
                : (value) => setState(() => _enabled = value),
          ),
          if (_enabled) ...[
            const SizedBox(height: 12),
            TextFormField(
              controller: _address,
              enabled: !_busy,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '代理地址与端口',
                hintText: 'http://127.0.0.1:7890',
                border: OutlineInputBorder(),
              ),
              validator: (value) {
                final address = normalizeManualHttpProxy(value ?? '');
                return address == null || address.isEmpty
                    ? '请填写 HTTP 代理地址和端口，例如 127.0.0.1:7890'
                    : null;
              },
            ),
            const SizedBox(height: 12),
            const Text(
              '若代理运行在兼容环境中，请使用它提供的可访问地址。开启局域网接入后，可能需要填写局域网 IP，不能直接使用 127.0.0.1。',
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _busy ? null : () => _run(save: false),
              child: const Text('测试代理连接'),
            ),
          ],
          const SizedBox(height: 16),
          const Text(
            '手动代理用于来源请求、图片和缓存；来源明确要求直连时仍按直连处理。代理无法连接时会报错，不会自动退回直连。此设置仅保存在当前设备。',
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : () => _run(save: true),
            child: const Text('应用设置'),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_result != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_result!),
            ),
        ],
      ),
    ),
  );
}
