import 'package:flutter/material.dart';

import '../services/account_service.dart';

class AccountPage extends StatefulWidget {
  final AccountService? service;
  const AccountPage({super.key, this.service});
  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  late final AccountService _account =
      widget.service ?? AccountService.instance;
  final _form = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _code = TextEditingController();
  bool _register = false;
  bool _showPassword = false;
  bool _includeReaderSettings = true;

  @override
  void initState() {
    super.initState();
    _account.initialize();
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _confirm.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final success = await _account.authenticate(
      _username.text,
      _password.text,
      activationCode: _register ? _code.text : null,
    );
    if (success && mounted) {
      _password.clear();
      _confirm.clear();
      _code.clear();
    }
  }

  Future<void> _sync({required bool upload}) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(upload ? '本地同步云端' : '云端同步本地'),
        content: Text(
          (upload
                  ? '用本机的书架、历史和阅读进度覆盖云端。云端独有的记录会被移除；本机数据不变。确定上传吗？'
                  : '用云端的书架、历史和阅读进度覆盖本机。本机独有的网络作品记录会被移除；云端数据不变。确定下载吗？') +
              (_includeReaderSettings
                  ? '\n\n同时${upload ? '上传本机' : '恢复同系统的'}阅读设置，包括字体、排版、背景和阅读模式。'
                  : '\n\n这次不更改阅读设置。'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(upload ? '确认上传' : '确认下载'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    final success = upload
        ? await _account.uploadToCloud(
            includeReaderSettings: _includeReaderSettings,
          )
        : await _account.downloadToLocal(
            includeReaderSettings: _includeReaderSettings,
          );
    if (success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(upload ? '本机数据已上传，云端已替换' : '云端数据已下载，本机已替换')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _account,
    builder: (context, _) {
      final session = _account.session;
      final enabled =
          _account.initialized && _account.configured && !_account.busy;
      return Scaffold(
        appBar: AppBar(title: const Text('账号与同步')),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (!_account.initialized || _account.busy)
                  const LinearProgressIndicator(),
                if (!_account.configured)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 20),
                    child: Text('同步服务尚未部署，暂时无法注册和登录。仍可使用 JSON 导入与导出。'),
                  ),
                if (session == null) ...[
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('登录')),
                      ButtonSegment(value: true, label: Text('激活码注册')),
                    ],
                    selected: {_register},
                    onSelectionChanged: _account.busy
                        ? null
                        : (values) {
                            setState(() {
                              _register = values.single;
                              _confirm.clear();
                              _code.clear();
                            });
                          },
                  ),
                  const SizedBox(height: 24),
                  Form(
                    key: _form,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextFormField(
                          controller: _username,
                          enabled: !_account.busy,
                          autocorrect: false,
                          keyboardType: TextInputType.text,
                          textInputAction: TextInputAction.next,
                          maxLength: 32,
                          decoration: const InputDecoration(
                            labelText: '用户名',
                            helperText: '3–32 位字母、数字或下划线，字母不区分大小写',
                          ),
                          validator: (value) =>
                              AccountService.validateUsername(value ?? ''),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _password,
                          enabled: !_account.busy,
                          obscureText: !_showPassword,
                          autocorrect: false,
                          enableSuggestions: false,
                          maxLength: 128,
                          textInputAction: _register
                              ? TextInputAction.next
                              : TextInputAction.done,
                          onFieldSubmitted: (_) {
                            if (!_register && enabled) _submit();
                          },
                          decoration: InputDecoration(
                            labelText: '密码',
                            helperText: '8–128 个字符',
                            suffixIcon: IconButton(
                              tooltip: _showPassword ? '隐藏密码' : '显示密码',
                              onPressed: () => setState(
                                () => _showPassword = !_showPassword,
                              ),
                              icon: Icon(
                                _showPassword
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                              ),
                            ),
                          ),
                          validator: (value) =>
                              AccountService.validatePassword(value ?? ''),
                        ),
                        if (_register) ...[
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _confirm,
                            enabled: !_account.busy,
                            obscureText: !_showPassword,
                            autocorrect: false,
                            enableSuggestions: false,
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(
                              labelText: '确认密码',
                            ),
                            validator: (value) =>
                                value == _password.text ? null : '两次输入的密码不一致',
                          ),
                          const SizedBox(height: 20),
                          TextFormField(
                            controller: _code,
                            enabled: !_account.busy,
                            autocorrect: false,
                            enableSuggestions: false,
                            maxLength: 128,
                            textInputAction: TextInputAction.done,
                            onFieldSubmitted: (_) {
                              if (enabled) _submit();
                            },
                            decoration: const InputDecoration(
                              labelText: '激活码',
                              helperText: '由维护者提供，每个激活码只能注册一个账号',
                            ),
                            validator: (value) =>
                                (value ?? '').trim().isEmpty ? '请填写激活码' : null,
                          ),
                        ],
                        const SizedBox(height: 20),
                        FilledButton(
                          onPressed: enabled ? _submit : null,
                          child: Text(_register ? '注册并登录' : '登录'),
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.account_circle_outlined),
                      title: Text(session.username),
                      subtitle: const Text('已登录'),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    _account.lastSync == null
                        ? '还没有同步过'
                        : '上次同步：${_date(_account.lastSync!)}',
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('同步此系统的阅读设置'),
                    subtitle: const Text('同系统换机恢复字体、排版、背景和阅读模式；其他系统保留各自设置'),
                    value: _includeReaderSettings,
                    onChanged: enabled
                        ? (value) =>
                              setState(() => _includeReaderSettings = value)
                        : null,
                  ),
                  FilledButton.icon(
                    onPressed: enabled ? () => _sync(upload: true) : null,
                    icon: const Icon(Icons.cloud_upload_outlined),
                    label: const Text('本地同步云端'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: enabled ? () => _sync(upload: false) : null,
                    icon: const Icon(Icons.cloud_download_outlined),
                    label: const Text('云端同步本地'),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '两个按钮都按所选方向覆盖数据，不会自动合并。删书后用“本地同步云端”上传，再在其他设备用“云端同步本地”下载。\n\n建议覆盖前先用 JSON 导出备份。本地文件、离线缓存和插件账号不参与同步。',
                  ),
                  const SizedBox(height: 24),
                  OutlinedButton(
                    onPressed: _account.busy ? null : _account.logout,
                    child: const Text('退出登录'),
                  ),
                  const SizedBox(height: 8),
                  const Text('退出登录会保留本机书架和历史。'),
                ],
                if (_account.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 20),
                    child: Text(
                      _account.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );

  String _date(DateTime value) {
    final date = value.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
  }
}
