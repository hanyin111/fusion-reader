import 'dart:convert';

class ExtensionException implements Exception {
  final String package;
  final String message;
  ExtensionException(this.package, this.message);
  @override
  String toString() => '[$package] $message';
}

/// QuickJS returns the invocation's JSON string directly. JavaScriptCore's
/// handlePromise serializes it again, so only the outer envelope is unwrapped.
dynamic decodeExtensionResult(
  String raw, {
  required String package,
  required String method,
}) {
  dynamic decoded;
  try {
    decoded = jsonDecode(raw);
    if (decoded is String) decoded = jsonDecode(decoded);
  } on FormatException {
    throw ExtensionException(package, '$method() 返回了无法解析的结果');
  }
  if (decoded is! Map || decoded['ok'] is! bool) {
    throw ExtensionException(package, '$method() 返回格式不正确');
  }
  if (decoded['ok'] == true) return decoded['data'];
  throw ExtensionException(
    package,
    (decoded['error'] ?? '$method() 执行失败').toString(),
  );
}
