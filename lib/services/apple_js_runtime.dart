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
    enableHandlePromises();
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
    super.dispose();
    _messageCallback.close();
    JavascriptRuntime.channelFunctionsRegistered.remove(getEngineInstanceId());
  }
}
