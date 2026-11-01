import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/extension_login.dart';
import '../services/extension_manager.dart';

Future<void> openExtensionLogin(BuildContext context, String package) async {
  try {
    final manager = ExtensionManager.instance;
    final service = await manager.ensureLoaded(package);
    if (!context.mounted) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            ExtensionLoginPage(title: service.meta.name, client: service),
      ),
    );
    if (changed == true) {
      await manager.reload(package);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('来源登录状态已更新')));
      }
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法打开来源登录，请稍后重试')));
    }
  }
}

class ExtensionLoginPage extends StatefulWidget {
  final String title;
  final ExtensionLoginClient client;
  const ExtensionLoginPage({
    super.key,
    required this.title,
    required this.client,
  });

  @override
  State<ExtensionLoginPage> createState() => _ExtensionLoginPageState();
}

class _ExtensionLoginPageState extends State<ExtensionLoginPage>
    with WidgetsBindingObserver {
  ExtensionLoginStatus? _status;
  ExtensionLoginChallenge? _challenge;
  DateTime? _expires;
  Timer? _timer;
  bool _busy = true;
  bool _polling = false;
  bool _active = true;
  bool _success = false;
  bool _expired = false;
  bool _scanned = false;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(widget.client.cancelLogin().catchError((Object _) {}));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    _timer?.cancel();
    if (_active && mounted) {
      if (_success) {
        Navigator.pop(context, true);
      } else if (_challenge != null && !_expired && _error == null) {
        _schedule();
        unawaited(_poll());
      }
    }
  }

  Future<void> _initialize() async {
    final generation = ++_generation;
    try {
      final status = await widget.client.loginStatus().timeout(
        const Duration(seconds: 20),
      );
      if (!mounted || generation != _generation) return;
      _status = status;
      if (status.loggedIn) {
        setState(() => _busy = false);
      } else {
        await _generate();
      }
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _busy = false;
        _error = '无法连接登录服务，请稍后重试';
      });
    }
  }

  Future<void> _generate() async {
    final generation = ++_generation;
    _timer?.cancel();
    setState(() {
      _busy = true;
      _error = null;
      _expired = false;
      _scanned = false;
      _challenge = null;
      _polling = false;
    });
    try {
      await widget.client.cancelLogin().timeout(const Duration(seconds: 10));
      if (!mounted || generation != _generation) return;
      final challenge = await widget.client.beginLogin().timeout(
        const Duration(seconds: 20),
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _challenge = challenge;
        _expires = DateTime.now().add(challenge.expiresIn);
        _busy = false;
      });
      _schedule();
    } catch (_) {
      if (!mounted || generation != _generation) return;
      unawaited(widget.client.cancelLogin().catchError((Object _) {}));
      setState(() {
        _busy = false;
        _error = '二维码获取失败，请稍后重试';
      });
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (_active && _challenge != null) {
      _timer = Timer.periodic(_challenge!.interval, (_) => unawaited(_poll()));
    }
  }

  Future<void> _poll() async {
    if (_polling ||
        !_active ||
        _busy ||
        _expired ||
        _success ||
        _challenge == null) {
      return;
    }
    if (DateTime.now().isAfter(_expires!)) {
      _markExpired();
      return;
    }
    final generation = _generation;
    _polling = true;
    try {
      final result = await widget.client.pollLogin().timeout(
        const Duration(seconds: 20),
      );
      if (!mounted || generation != _generation) return;
      switch (result.phase) {
        case ExtensionLoginPhase.waiting:
          break;
        case ExtensionLoginPhase.scanned:
          setState(() => _scanned = true);
        case ExtensionLoginPhase.success:
          _timer?.cancel();
          _success = true;
          if (_active) Navigator.pop(context, true);
        case ExtensionLoginPhase.expired:
        case ExtensionLoginPhase.cancelled:
          _markExpired();
      }
    } catch (_) {
      if (!mounted || generation != _generation) return;
      _timer?.cancel();
      setState(() => _error = '登录连接中断，请刷新二维码后重试');
    } finally {
      if (generation == _generation) _polling = false;
    }
  }

  void _markExpired() {
    _timer?.cancel();
    setState(() => _expired = true);
    unawaited(widget.client.cancelLogin().catchError((Object _) {}));
  }

  Future<void> _logout() async {
    setState(() => _busy = true);
    try {
      await widget.client.logout().timeout(const Duration(seconds: 20));
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '退出登录失败，请重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        '${widget.title} · 登录',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_busy)
                  const CircularProgressIndicator()
                else if (_status?.loggedIn == true) ...[
                  const Icon(Icons.verified_user_outlined, size: 56),
                  const SizedBox(height: 16),
                  Text(_status!.username.isEmpty ? '已登录' : _status!.username),
                  const SizedBox(height: 20),
                  OutlinedButton(
                    onPressed: _logout,
                    child: const Text('退出来源账号'),
                  ),
                  if (_error != null)
                    Text(_error!, textAlign: TextAlign.center),
                ] else ...[
                  Text(
                    _scanned ? '已扫码，请在对应应用中确认' : '扫码登录',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 20),
                  if (_challenge != null && !_expired && _error == null)
                    QrImageView(
                      data: _challenge!.qrText,
                      size: 260,
                      backgroundColor: Colors.white,
                      errorStateBuilder: (_, _) => const SizedBox(
                        height: 180,
                        child: Center(child: Text('二维码无法生成，请刷新')),
                      ),
                    ),
                  if (_expired)
                    const Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('二维码已过期，请刷新'),
                    ),
                  if (_challenge?.message.isNotEmpty == true &&
                      _error == null) ...[
                    const SizedBox(height: 16),
                    Text(_challenge!.message, textAlign: TextAlign.center),
                  ],
                  const SizedBox(height: 16),
                  if (_error != null)
                    Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _generate,
                    icon: const Icon(Icons.refresh),
                    label: const Text('刷新二维码'),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '同一部手机可先截图，再用对应应用的扫一扫从相册识别。',
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 20),
                const Text(
                  '来源登录状态仅保存在当前设备。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
