import 'dart:convert';

import 'package:dio/dio.dart';

import 'library_backup.dart';

class AccountException implements Exception {
  final String message;
  final bool expired;
  final bool conflict;
  const AccountException(
    this.message, {
    this.expired = false,
    this.conflict = false,
  });
  @override
  String toString() => message;
}

class AccountSession {
  final String userId;
  final String username;
  final String token;
  final DateTime expiresAt;
  const AccountSession({
    required this.userId,
    required this.username,
    required this.token,
    required this.expiresAt,
  });

  static AccountSession fromJson(dynamic raw) {
    if (raw is! Map || raw['user'] is! Map) {
      throw const FormatException('Invalid session');
    }
    final user = raw['user'] as Map;
    final id = user['id'];
    final username = user['username'];
    final token = raw['token'];
    final expiry = raw['expiresAt'];
    final date = expiry is String ? DateTime.tryParse(expiry) : null;
    if (id is! String ||
        id.isEmpty ||
        id.length > 128 ||
        username is! String ||
        !RegExp(r'^[a-z0-9_]{3,32}$').hasMatch(username) ||
        token is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{32,1024}$').hasMatch(token) ||
        date == null) {
      throw const FormatException('Invalid session');
    }
    return AccountSession(
      userId: id,
      username: username,
      token: token,
      expiresAt: date.toUtc(),
    );
  }

  Map<String, dynamic> toJson() => {
    'user': {'id': userId, 'username': username},
    'token': token,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
  };
}

class CloudLibrary {
  final int revision;
  final LibraryBackup snapshot;
  const CloudLibrary(this.revision, this.snapshot);
}

abstract interface class AccountApi {
  String get serviceId;
  bool get configured;
  Future<AccountSession> authenticate(
    String username,
    String password, {
    String? activationCode,
  });
  Future<void> logout(String token);
  Future<CloudLibrary> download(String token);
  Future<int> upload(
    String token,
    int expectedRevision,
    LibraryBackup snapshot,
  );
}

/// Deliberately independent of source networking: HTTPS with normal certificate
/// checks and no redirects that could forward credentials to another origin.
class HttpAccountApi implements AccountApi {
  static const buildUrl = String.fromEnvironment('FUSION_SYNC_URL');
  final Dio _dio;
  final Uri? _base;
  final String _url;

  HttpAccountApi({
    String baseUrl = buildUrl,
    Dio? dio,
    bool allowLocalHttp = false,
  }) : _url = baseUrl.trim().replaceFirst(RegExp(r'/+$'), ''),
       _base = _validate(baseUrl, allowLocalHttp),
       _dio = dio ?? Dio() {
    _dio.options.connectTimeout = const Duration(seconds: 15);
  }

  static Uri? _validate(String value, bool allowLocalHttp) {
    final uri = Uri.tryParse(value.trim().replaceFirst(RegExp(r'/+$'), ''));
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.scheme != 'https' &&
            !(allowLocalHttp &&
                uri.scheme == 'http' &&
                const ['127.0.0.1', 'localhost', '::1'].contains(uri.host)))) {
      return null;
    }
    return uri;
  }

  @override
  String get serviceId => _url;
  @override
  bool get configured => _base != null;

  Future<Map> _request(
    String method,
    String path, {
    String? token,
    dynamic data,
    Duration deadline = const Duration(seconds: 60),
  }) async {
    if (!configured) {
      throw const AccountException('同步服务尚未部署，暂时无法连接。');
    }
    final cancel = CancelToken();
    try {
      final response = await _dio
          .request<String>(
            '$_base$path',
            data: data,
            cancelToken: cancel,
            options: Options(
              method: method,
              headers: {
                if (token != null) 'Authorization': 'Bearer $token',
                'Accept': 'application/json',
              },
              contentType: Headers.jsonContentType,
              responseType: ResponseType.plain,
              followRedirects: false,
              sendTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(seconds: 30),
              validateStatus: (_) => true,
            ),
            onReceiveProgress: (received, total) {
              if (received > LibraryBackup.maxBytes + 262144 ||
                  total > LibraryBackup.maxBytes + 262144) {
                cancel.cancel();
              }
            },
          )
          .timeout(
            deadline,
            onTimeout: () {
              cancel.cancel();
              throw const AccountException('连接同步服务超时，请稍后重试。');
            },
          );
      final status = response.statusCode ?? 0;
      dynamic json;
      if (utf8.encode(response.data ?? '').length >
          LibraryBackup.maxBytes + 262144) {
        throw const AccountException('云端数据过大，无法同步。');
      }
      try {
        json = jsonDecode(response.data ?? '');
      } on FormatException {
        json = null;
      }
      if (status == 401 && token != null) {
        throw const AccountException('登录已失效，请重新登录。', expired: true);
      }
      if (status == 409 && path == '/v1/library') {
        throw const AccountException('云端数据已更新。', conflict: true);
      }
      if (status < 200 || status >= 300) {
        final code = json is Map ? json['error'] : null;
        final message = switch (code) {
          'invalid_activation_code' => '激活码无效、已使用或已过期。',
          'username_taken' => '这个用户名已被使用。',
          'invalid_credentials' => '用户名或密码不正确。',
          'invalid_input' => '请检查填写的用户名、密码和激活码。',
          'payload_too_large' => '书架和历史数据过大，无法同步。',
          _ => status == 429 ? '操作太频繁，请稍后再试。' : '同步服务暂时不可用，请稍后重试。',
        };
        // Login's 401 is intentionally distinct from an expired session.
        throw AccountException(message);
      }
      if (json is! Map) {
        throw const AccountException('服务返回的数据格式不正确，请稍后重试。');
      }
      return json;
    } on DioException {
      throw const AccountException('连接同步服务失败，请检查网络后重试。');
    }
  }

  @override
  Future<AccountSession> authenticate(
    String username,
    String password, {
    String? activationCode,
  }) async {
    final json = await _request(
      'POST',
      activationCode == null ? '/v1/auth/login' : '/v1/auth/register',
      data: {
        'username': username,
        'password': password,
        'activationCode': ?activationCode,
      },
    );
    try {
      final session = AccountSession.fromJson(json);
      if (!session.expiresAt.isAfter(DateTime.now())) {
        throw const FormatException('Expired');
      }
      return session;
    } on FormatException {
      throw const AccountException('登录响应无效，请稍后重试。');
    }
  }

  @override
  Future<void> logout(String token) async {
    await _request(
      'POST',
      '/v1/auth/logout',
      token: token,
      deadline: const Duration(seconds: 5),
    );
  }

  @override
  Future<CloudLibrary> download(String token) async {
    final json = await _request('GET', '/v1/library', token: token);
    try {
      return CloudLibrary(
        _revision(json['revision']),
        LibraryBackup.decode(utf8.encode(jsonEncode(json['snapshot']))),
      );
    } on FormatException {
      throw const AccountException('云端书架数据无效，本地数据未改动。');
    }
  }

  @override
  Future<int> upload(
    String token,
    int expectedRevision,
    LibraryBackup snapshot,
  ) async {
    final json = await _request(
      'PUT',
      '/v1/library',
      token: token,
      data: {
        'expectedRevision': expectedRevision,
        'snapshot': jsonDecode(utf8.decode(snapshot.encodeBytes())),
      },
    );
    try {
      final revision = _revision(json['revision']);
      if (revision != expectedRevision + 1) {
        throw const FormatException('Unexpected revision');
      }
      return revision;
    } on FormatException {
      throw const AccountException('同步响应无效，请重试。');
    }
  }

  static int _revision(dynamic value) {
    if (value is! int || value < 0 || value > 9007199254740991) {
      throw const FormatException('Invalid revision');
    }
    return value;
  }
}
