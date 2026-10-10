import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:grpc/grpc.dart';

/// Raw unary transport; service names and protobuf schemas stay in plugins.
class ExtensionGrpc {
  static Future<String> request(Map payload) async {
    final uri = Uri.tryParse((payload['endpoint'] ?? '').toString());
    final method = (payload['method'] ?? '').toString();
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        !RegExp(r'^/[a-zA-Z0-9_.]+/[a-zA-Z0-9_]+$').hasMatch(method)) {
      throw const FormatException('无效 gRPC 接口');
    }
    final encoded = (payload['data'] ?? '').toString();
    if (encoded.length > 1024 * 1024) {
      throw const FormatException('gRPC 请求过大');
    }
    final bytes = base64Decode(encoded);
    final certificate = payload['certificate']?.toString();
    // Some sources ship a self-signed, hostname-less server certificate.
    // Accept only that exact certificate, never arbitrary TLS failures.
    final pin = certificate == null
        ? null
        : sha256.convert(
            base64Decode(
              certificate
                  .replaceAll(RegExp(r'-----[^-]+-----'), '')
                  .replaceAll(RegExp(r'\s'), ''),
            ),
          );
    final channel = ClientChannel(
      uri.host,
      port: uri.hasPort ? uri.port : 443,
      options: ChannelOptions(
        credentials: ChannelCredentials.secure(
          certificates: certificate == null ? null : utf8.encode(certificate),
          onBadCertificate: pin == null
              ? null
              : (cert, host) =>
                    (host == uri.host || host == '${uri.host}:${uri.port}') &&
                    sha256.convert(cert.der).toString() == pin.toString(),
        ),
        connectTimeout: const Duration(seconds: 5),
      ),
    );
    final metadata = <String, String>{};
    (payload['metadata'] as Map? ?? {}).forEach((key, value) {
      final name = key.toString();
      if (RegExp(r'^[a-z0-9][a-z0-9_-]*$').hasMatch(name) &&
          !name.endsWith('-bin')) {
        metadata[name] = value.toString();
      }
    });
    try {
      final call = channel.createCall<List<int>, List<int>>(
        ClientMethod(method, (data) => data, (data) {
          if (data.length > 8 * 1024 * 1024) {
            throw const FormatException('gRPC 响应过大');
          }
          return data;
        }),
        Stream.value(bytes),
        CallOptions(metadata: metadata, timeout: const Duration(seconds: 10)),
      );
      return base64Encode(await ResponseFuture(call));
    } finally {
      await channel.terminate();
    }
  }
}
