import 'dart:async';
import 'dart:typed_data';

import 'package:cupertino_http/cupertino_http.dart';
import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;

/// Use Apple's URL Loading System rather than Dart sockets on iOS. In
/// particular, do not replace its per-destination proxy/VPN/PAC decisions with
/// a single proxy address discovered for an unrelated probe URL.
class AppleHttpAdapter implements HttpClientAdapter {
  AppleHttpAdapter({http.Client? client}) : _client = client ?? _nativeClient();

  static http.Client _nativeClient() {
    final config = URLSessionConfiguration.ephemeralSessionConfiguration()
      ..cache = null
      // Dio's CookieManager owns the cookie jar, including script-supplied
      // cookies. Avoid a second, hidden store overriding those headers.
      ..httpShouldSetCookies = false;
    // Leave the session's proxy configuration at the system default.
    return CupertinoClient.fromSessionConfiguration(config);
  }

  final http.Client _client;
  final _active = <_RequestOperation>{};
  bool _closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_closed) throw StateError('HTTP adapter is closed');
    final operation = _RequestOperation(options);
    _active.add(operation);
    void finish() {
      _active.remove(operation);
      operation.finish();
    }

    if (cancelFuture != null) {
      unawaited(cancelFuture.then((_) => operation.cancel()));
    }
    final request =
        _SessionRequest(options.method, options.uri, requestStream, operation)
          ..followRedirects = options.followRedirects
          ..maxRedirects = options.maxRedirects;
    for (final entry in options.headers.entries) {
      if (entry.value == null) continue;
      final name = options.preserveHeaderCase
          ? entry.key
          : entry.key.toLowerCase();
      request.headers[name] = entry.value is List
          ? (entry.value as List).join(', ')
          : entry.value.toString();
    }
    final length =
        request.headers['content-length'] ?? request.headers['Content-Length'];
    if (length != null) request.contentLength = int.tryParse(length);

    // URLSession does not expose the socket-connect milestone. Bound waiting
    // for headers by the combined connect/receive budget, as native adapters
    // do, and enforce the receive timeout separately while streaming data.
    final headerTimeout =
        (options.connectTimeout ?? Duration.zero) +
        (options.receiveTimeout ?? Duration.zero);
    final timer = headerTimeout > Duration.zero
        ? Timer(headerTimeout, () => operation.receiveTimeout(headerTimeout))
        : null;
    try {
      final response = await Future.any([
        _client.send(request),
        operation.failure.future.then<http.StreamedResponse>((e) => throw e),
      ]);
      timer?.cancel();
      Stream<List<int>> stream = response.stream;
      final timeout = options.receiveTimeout;
      if (timeout != null && timeout > Duration.zero) {
        stream = stream.timeout(
          timeout,
          onTimeout: (sink) {
            operation.receiveTimeout(timeout);
            sink.addError(operation.error!);
            sink.close();
          },
        );
      }
      // Stream images and downloads without buffering the entire response.
      late StreamSubscription<List<int>> subscription;
      late StreamController<Uint8List> controller;
      controller = StreamController<Uint8List>(
        sync: true,
        onListen: () {
          subscription = stream.listen(
            (bytes) => controller.add(
              bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
            ),
            onError: (Object error, StackTrace stack) {
              controller.addError(operation.error ?? error, stack);
            },
            onDone: () {
              finish();
              unawaited(controller.close());
            },
          );
        },
        onPause: () => subscription.pause(),
        onResume: () => subscription.resume(),
        onCancel: () async {
          await subscription.cancel();
          finish();
        },
      );
      return ResponseBody(
        controller.stream,
        response.statusCode,
        headers: response.headers.map((key, value) => MapEntry(key, [value])),
        isRedirect: response.isRedirect,
        statusMessage: response.reasonPhrase,
        onClose: () {
          operation.cancel();
          finish();
        },
      );
    } catch (_) {
      finish();
      rethrow;
    } finally {
      timer?.cancel();
    }
  }

  @override
  void close({bool force = false}) {
    if (_closed) return;
    _closed = true;
    if (force) {
      for (final operation in _active.toList()) {
        operation.cancel();
      }
    }
    _client.close();
  }
}

class _RequestOperation {
  _RequestOperation(this.options);
  final RequestOptions options;
  final abort = Completer<void>();
  final failure = Completer<DioException>();
  DioException? error;
  bool _finished = false;

  void fail(DioException reason) {
    if (_finished || error != null) return;
    error = reason;
    failure.complete(reason);
    if (!abort.isCompleted) abort.complete();
  }

  void cancel() => fail(
    DioException.requestCancelled(
      requestOptions: options,
      reason: 'Request cancelled',
    ),
  );
  void receiveTimeout(Duration timeout) => fail(
    DioException.receiveTimeout(timeout: timeout, requestOptions: options),
  );

  void finish() {
    _finished = true;
    // Release the native abort callback when a successful request completes.
    if (!abort.isCompleted) abort.complete();
    if (!failure.isCompleted) {
      failure.complete(DioException(requestOptions: options));
    }
  }
}

/// Forward upload data without collecting it in memory. CupertinoClient
/// supports Abortable and cancels the corresponding URLSessionTask.
class _SessionRequest extends http.BaseRequest with http.Abortable {
  _SessionRequest(super.method, super.url, this._body, this._operation);
  final Stream<Uint8List>? _body;
  final _RequestOperation _operation;
  @override
  Future<void> get abortTrigger => _operation.abort.future;

  @override
  http.ByteStream finalize() {
    super.finalize();
    Stream<List<int>> stream = _body ?? const Stream<List<int>>.empty();
    final timeout = _operation.options.sendTimeout;
    if (timeout != null && timeout > Duration.zero) {
      stream = stream.timeout(
        timeout,
        onTimeout: (sink) {
          _operation.fail(
            DioException.sendTimeout(
              timeout: timeout,
              requestOptions: _operation.options,
            ),
          );
          sink.addError(_operation.error!);
          sink.close();
        },
      );
    }
    return http.ByteStream(stream);
  }
}
