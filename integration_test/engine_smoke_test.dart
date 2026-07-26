// Minimal engine bring-up test to isolate native crashes.
// Run with:  flutter test integration_test/engine_smoke_test.dart -d windows
// ignore_for_file: avoid_print
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_js/flutter_js.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/services/extension_runtime.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('engine smoke test', (tester) async {
    await tester.runAsync(() async {
      print('STEP 1: create runtime');
      final rt = getJavascriptRuntime(xhr: false);
      print('STEP 2: evaluate 1+1');
      final r = rt.evaluate('1+1');
      print('STEP 2 result: ${r.stringResult}');

      print('STEP 3: promise roundtrip');
      final p = await rt.evaluateAsync('Promise.resolve(41+1).then(x => "v" + x)');
      rt.executePendingJob();
      final pr = await rt.handlePromise(p, timeout: const Duration(seconds: 10));
      print('STEP 3 result: ${pr.stringResult}');

      print('STEP 4: onMessage bridge');
      rt.onMessage('ping', (args) {
        print('STEP 4 dart got: $args');
        return null;
      });
      rt.evaluate('sendMessage("ping", JSON.stringify({id: 1, payload: "hello"}))');
      print('STEP 4 done');

      print('STEP 5: storage init');
      await Storage.init();

      print('STEP 6: load prelude + mangadex');
      final prelude = await rootBundle.loadString('assets/js/runtime.js');
      final script = await rootBundle.loadString('assets/extensions/mangadex.js');
      final meta = ExtensionMeta.parse(script)!;
      print('STEP 6 meta: ${meta.package} ${meta.type}');
      final service = ExtensionService(meta: meta, script: script, prelude: prelude);
      await service.init();
      print('STEP 7: service initialized, calling latest(1)');
      final items = await service.latest(1);
      print('STEP 8: latest -> ${items.length} items; first: ${items.isNotEmpty ? items.first.title : '-'}');
      expect(items, isNotEmpty);
      rt.dispose();
    });
  }, timeout: const Timeout(Duration(minutes: 5)));
}
