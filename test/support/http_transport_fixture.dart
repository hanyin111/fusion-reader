import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Local-only transport fixture: no live content or external credentials.
class HttpTransportFixture {
  HttpTransportFixture._(this.server) {
    server.listen(_handle);
  }
  final HttpServer server;
  final receivedSlowRequest = Completer<void>();
  final release = Completer<void>();
  final paths = <String>[];

  static Future<HttpTransportFixture> start() async => HttpTransportFixture._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
  );
  String url(String path) => 'http://127.0.0.1:${server.port}$path';

  Future<void> _handle(HttpRequest request) async {
    paths.add(request.uri.path);
    final response = request.response;
    try {
      switch (request.uri.path) {
        case '/echo':
          response.headers.contentType = ContentType.json;
          response.write(
            jsonEncode({
              'method': request.method,
              'cookie': request.headers.value('cookie'),
              'userAgent': request.headers.value('user-agent'),
              'body': await utf8.decoder.bind(request).join(),
            }),
          );
        case '/cookies':
          response.headers.add('set-cookie', 'first=one; Path=/');
          response.headers.add(
            'set-cookie',
            'second=two; Expires=Wed, 21 Oct 2037 07:28:00 GMT; Path=/',
          );
          response.write('saved');
        case '/redirect':
          response.statusCode = 302;
          response.headers.set('location', '/target');
        case '/target':
          response.write('redirected');
        case '/bytes':
          response.headers.contentType = ContentType.binary;
          response.add([0, 1, 2, 255]);
        case '/stream':
          response.bufferOutput = false;
          response.add([1, 2, 3]);
          await response.flush();
          await release.future;
          response.add([4, 5]);
        case '/slow':
          if (!receivedSlowRequest.isCompleted) receivedSlowRequest.complete();
          await release.future;
          response.write('late');
        default:
          response.statusCode = 403;
          response.write('denied');
      }
      await response.close();
    } on Exception {
      // Expected when the client cancels a stream or times out.
      response.close().ignore();
    }
  }

  Future<void> close() async {
    if (!release.isCompleted) release.complete();
    await server.close(force: true);
  }
}
