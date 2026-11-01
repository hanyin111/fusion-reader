class ExtensionLoginStatus {
  final bool loggedIn;
  final String username;

  const ExtensionLoginStatus({required this.loggedIn, this.username = ''});

  factory ExtensionLoginStatus.fromJson(dynamic raw) {
    if (raw is! Map || raw['loggedIn'] is! bool) {
      throw const FormatException('来源登录状态格式不正确');
    }
    return ExtensionLoginStatus(
      loggedIn: raw['loggedIn'],
      username: _text(raw['username'], 120),
    );
  }
}

class ExtensionLoginChallenge {
  final String qrText;
  final String message;
  final Duration expiresIn;
  final Duration interval;

  const ExtensionLoginChallenge({
    required this.qrText,
    this.message = '',
    this.expiresIn = const Duration(minutes: 3),
    this.interval = const Duration(seconds: 3),
  });

  factory ExtensionLoginChallenge.fromJson(dynamic raw) {
    if (raw is! Map ||
        raw['qrText'] is! String ||
        (raw['qrText'] as String).isEmpty ||
        (raw['qrText'] as String).length > 4096) {
      throw const FormatException('来源未返回有效的登录二维码');
    }
    int number(String key, int fallback) =>
        int.tryParse('${raw[key]}') ?? fallback;
    return ExtensionLoginChallenge(
      qrText: raw['qrText'],
      message: _text(raw['message'], 240),
      expiresIn: Duration(seconds: number('expiresIn', 180).clamp(30, 600)),
      interval: Duration(seconds: number('pollInterval', 3).clamp(2, 15)),
    );
  }
}

enum ExtensionLoginPhase { waiting, scanned, success, expired, cancelled }

class ExtensionLoginPoll {
  final ExtensionLoginPhase phase;
  const ExtensionLoginPoll(this.phase);

  factory ExtensionLoginPoll.fromJson(dynamic raw) {
    if (raw is! Map) throw const FormatException('来源登录响应格式不正确');
    for (final phase in ExtensionLoginPhase.values) {
      if (phase.name == raw['status']) return ExtensionLoginPoll(phase);
    }
    throw const FormatException('来源登录响应格式不正确');
  }
}

String _text(dynamic raw, int limit) {
  final text = (raw ?? '').toString().replaceAll(
    RegExp(r'[\x00-\x1f\x7f]'),
    ' ',
  );
  return text.length > limit ? text.substring(0, limit) : text;
}

abstract interface class ExtensionLoginClient {
  Future<ExtensionLoginStatus> loginStatus();
  Future<ExtensionLoginChallenge> beginLogin();
  Future<ExtensionLoginPoll> pollLogin();
  Future<void> cancelLogin();
  Future<void> logout();
}
