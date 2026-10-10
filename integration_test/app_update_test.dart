import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:fusion_reader/pages/app_update_page.dart';
import 'package:fusion_reader/services/app_update_controller.dart';

import 'linovelib_test.dart' show isolateLinovelibTestStorage;

// Opt-in real GitHub check; routine CI uses synthetic responses.
const liveCheck = bool.fromEnvironment('APP_UPDATE_LIVE');

void main() {
  isolateLinovelibTestStorage();
  testWidgets(
    'native update page reads the installed version and latest release',
    (tester) async {
      final controller = AppUpdateController();
      final completed = Completer<void>();
      controller.addListener(() {
        if (controller.phase != AppUpdatePhase.checking &&
            !completed.isCompleted) {
          completed.complete();
        }
      });
      final helper = await rootBundle.loadString('assets/update_windows.ps1');
      expect(helper, contains('WaitForExit(60000)'));
      expect(helper, contains('rollback'));
      await tester.pumpWidget(
        MaterialApp(home: AppUpdatePage(controller: controller)),
      );
      await tester.runAsync(
        () => completed.future.timeout(const Duration(seconds: 30)),
      );
      await tester.pumpAndSettle();
      expect(controller.error, isEmpty);
      final installed = await PackageInfo.fromPlatform();
      expect(controller.currentVersion, installed.version);
      expect(controller.release, isNotNull);
      expect(find.textContaining('当前版本 v${installed.version}'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !liveCheck,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
