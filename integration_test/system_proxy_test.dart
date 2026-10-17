import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:fusion_reader/services/proxy_resolver.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS system proxy bridge is registered on the real Flutter engine', (tester) async {
    if (!Platform.isIOS) return;
    final settings = await SystemProxyResolver.channel.invokeMapMethod<String, dynamic>('settings');
    expect(settings, isNotNull);
    expect(settings!['http'], isA<String>());
    expect(settings['https'], isA<String>());
    expect(settings['bypass'], isA<List>());
    final resolver = SystemProxyResolver(environment: {});
    await resolver.refresh();
    expect(resolver.findProxy(Uri.parse('file:///local-book')), 'DIRECT');
  });
}
