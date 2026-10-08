import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/services/extension_result.dart';

dynamic decode(String raw) =>
    decodeExtensionResult(raw, package: 'test', method: 'latest');

void main() {
  for (final apple in [false, true]) {
    String encode(Map<String, dynamic> result) {
      final raw = jsonEncode(result);
      return apple ? jsonEncode(raw) : raw;
    }

    group(apple ? 'JavaScriptCore results' : 'QuickJS results', () {
      test('successful load with null is not an error', () {
        expect(decode(encode({'ok': true, 'data': null})), isNull);
      });
      test('preserves structured values and escaped Unicode text', () {
        final data = [
          {'title': '中文 "标题"\n🌸', 'url': '/1', 'count': 3},
        ];
        expect(decode(encode({'ok': true, 'data': data})), data);
      });
      test('does not decode JSON text inside data', () {
        const text = '{"ok":false,"error":"this is novel text"}';
        expect(decode(encode({'ok': true, 'data': text})), text);
      });
      test('preserves actual extension failures', () {
        expect(
          () => decode(encode({'ok': false, 'error': '请先登录'})),
          throwsA(
            isA<ExtensionException>()
                .having((e) => e.package, 'package', 'test')
                .having((e) => e.message, 'message', '请先登录'),
          ),
        );
      });
    });
  }
  test('invalid envelopes produce a useful error', () {
    for (final raw in ['undefined', 'null', '[]', '{}', '"bad json"']) {
      expect(() => decode(raw), throwsA(isA<ExtensionException>()));
    }
  });
}
