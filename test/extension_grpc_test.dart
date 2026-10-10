import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/services/extension_grpc.dart';
import 'package:grpc/grpc.dart';

class EchoService extends Service {
  EchoService() {
    $addMethod(
      ServiceMethod<List<int>, List<int>>(
        'Echo',
        (_, Future<List<int>> data) => data,
        false,
        false,
        (bytes) => bytes,
        (bytes) => bytes,
      ),
    );
  }
  @override
  String get $name => 'test.Transport';
}

void main() {
  late Server server;
  late Map<String, dynamic> payload;
  setUp(() async {
    final certificate = await File(
      'test/fixtures/grpc/server.crt',
    ).readAsBytes();
    server = Server.create(services: [EchoService()]);
    await server.serve(
      address: InternetAddress.loopbackIPv4,
      port: 0,
      security: ServerTlsCredentials(
        certificate: certificate,
        privateKey: await File(
          'test/fixtures/grpc/server-test-only.key',
        ).readAsBytes(),
      ),
    );
    payload = {
      'endpoint': 'https://127.0.0.1:${server.port}',
      'method': '/test.Transport/Echo',
      'certificate': utf8.decode(certificate),
      'data': base64Encode([0, 1, 127, 128, 255]),
    };
  });
  tearDown(() => server.shutdown());

  test(
    'raw unary transport accepts only the explicitly pinned certificate',
    () async {
      final response = await ExtensionGrpc.request(payload);
      expect(base64Decode(response), [0, 1, 127, 128, 255]);
      payload['certificate'] = await File(
        'test/fixtures/grpc/other.crt',
      ).readAsString();
      await expectLater(
        ExtensionGrpc.request(payload),
        throwsA(isA<GrpcError>()),
      );
    },
  );
  test(
    'TLS verification remains enabled without a plugin certificate',
    () async {
      payload.remove('certificate');
      await expectLater(
        ExtensionGrpc.request(payload),
        throwsA(isA<GrpcError>()),
      );
    },
  );
  test(
    'malformed methods and cleartext endpoints are rejected before connecting',
    () async {
      payload['method'] = '/invalid';
      await expectLater(ExtensionGrpc.request(payload), throwsFormatException);
      payload['method'] = '/test.Transport/Echo';
      payload['endpoint'] = 'http://127.0.0.1:${server.port}';
      await expectLater(ExtensionGrpc.request(payload), throwsFormatException);
    },
  );
}
