import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:flutter_js/flutter_js.dart';
import 'package:flutter_js/javascriptcore/binding/js_object_ref.dart'
    show JSObjectCallAsFunctionCallback;
import 'package:flutter_js/javascriptcore/flutter_jscore.dart';
import 'package:flutter_js/javascriptcore/jscore_runtime.dart';

/// flutter_js 0.8.7 stores its JavaScriptCore callback in a single static field.
/// Give each extension its own native callback, keeping JS values and channels
/// in the context that created them, even after another extension is loaded.
class AppleJsRuntime extends JavascriptCoreRuntime {
  late final NativeCallable<JSObjectCallAsFunctionCallback> _messageCallback;
  final Map<int, _PendingInvocation> _pending = {};
  int _nextInvocation = 0;
  bool _disposed = false;

  AppleJsRuntime() {
    _messageCallback =
        NativeCallable<JSObjectCallAsFunctionCallback>.isolateLocal(
          _sendMessage,
        );
    final function = JSObject.makeFunctionWithCallback(
      context,
      'sendMessage',
      _messageCallback.nativeFunction,
    );
    context.globalObject.setProperty(
      'sendMessage',
      JSValue(context, function.pointer),
      JSPropertyAttributes.kJSPropertyAttributeNone,
    );
    evaluate('globalThis.__fusionCalls = Object.create(null)');
  }

  /// Keep promises reachable inside their JS context instead of passing bare
  /// JSValueRef pointers through Dart futures. flutter_js does not protect
  /// those pointers from JavaScriptCore GC, and its polling survives disposal.
  Future<String> invoke(String expression, {required Duration timeout}) {
    if (_disposed) return Future.error(StateError('扩展已关闭'));
    final id = _nextInvocation++;
    final call = _PendingInvocation();
    _pending[id] = call;
    try {
      final started = evaluate('''
(function() {
  const call = globalThis.__fusionCalls[$id] = {state: 0, value: null};
  call.promise = Promise.resolve($expression).then(
    value => { call.value = value; call.state = 1; },
    error => {
      call.value = String(error && error.stack ? error.stack : error);
      call.state = 2;
    }
  );
  return 'ok';
})()
''');
      if (started.isError) throw StateError(started.stringResult);
      call.deadline = Timer(
        timeout,
        () => _finish(id, error: TimeoutException('脚本调用超时', timeout)),
      );
      call.poll = Timer.periodic(
        const Duration(milliseconds: 20),
        (_) => _poll(id),
      );
      _poll(id);
    } catch (error, stack) {
      _finish(id, error: error, stack: stack);
    }
    return call.completer.future;
  }

  void _poll(int id) {
    if (_disposed || !_pending.containsKey(id)) return;
    try {
      final result = evaluate('''
(function() {
  const call = globalThis.__fusionCalls[$id];
  return JSON.stringify({state: call.state, value: call.value});
})()
''');
      if (result.isError) throw StateError(result.stringResult);
      final state = jsonDecode(result.stringResult) as Map;
      if (state['state'] == 0) return;
      if (state['state'] == 1 && state['value'] is String) {
        _finish(id, value: state['value'] as String);
      } else {
        _finish(id, error: StateError('${state['value']}'));
      }
    } catch (error, stack) {
      _finish(id, error: error, stack: stack);
    }
  }

  void _finish(int id, {String? value, Object? error, StackTrace? stack}) {
    final call = _pending.remove(id);
    if (call == null) return;
    call.poll?.cancel();
    call.deadline?.cancel();
    if (!_disposed) {
      evaluate('delete globalThis.__fusionCalls[$id]');
    }
    if (error != null) {
      call.completer.completeError(error, stack);
    } else {
      call.completer.complete(value!);
    }
  }

  Pointer _sendMessage(
    Pointer ctx,
    Pointer function,
    Pointer thisObject,
    int argumentCount,
    Pointer<Pointer> arguments,
    Pointer<Pointer> exception,
  ) {
    try {
      if (argumentCount < 2) {
        throw ArgumentError('sendMessage needs two arguments');
      }
      final channel = JSValue(context, arguments[0]).string;
      final message = JSValue(context, arguments[1]).string!;
      final callback = JavascriptRuntime
          .channelFunctionsRegistered[getEngineInstanceId()]?[channel];
      if (callback == null) throw StateError('Unknown JS channel: $channel');
      final result = callback(jsonDecode(message));
      // ExtensionService resolves async handlers via __resolveBridge. All
      // native callbacks (including console and setTimeout) return synchronously.
      if (result is Future) throw StateError('Use the async extension bridge');
      return JSValue.makeFromJSONString(context, jsonEncode(result)).pointer;
    } catch (error) {
      if (exception != nullptr) {
        exception.value = JSValue.makeString(context, error.toString()).pointer;
      }
      return JSValue.makeUndefined(context).pointer;
    }
  }

  @override
  JsEvalResult evaluate(String js, {String? sourceUrl}) {
    // An upstream setTimeout may fire after an extension is reloaded. Never
    // pass a released JavaScriptCore context back into the native library.
    if (_disposed) return JsEvalResult('Runtime disposed', null, isError: true);
    return super.evaluate(js, sourceUrl: sourceUrl);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Stop all polling and wake callers before releasing the native context.
    for (final id in _pending.keys.toList()) {
      _finish(id, error: StateError('扩展已关闭'));
    }
    super.dispose();
    _messageCallback.close();
    JavascriptRuntime.channelFunctionsRegistered.remove(getEngineInstanceId());
  }
}

class _PendingInvocation {
  final Completer<String> completer = Completer<String>();
  Timer? poll;
  Timer? deadline;
}
