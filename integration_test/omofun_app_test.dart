import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/services/extension_manager.dart';
import 'package:fusion_reader/services/player_config.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';

import 'linovelib_test.dart' show isolateLinovelibTestStorage;

// Explicit local opt-in: no external service requests in routine CI tests.
const scriptPath = String.fromEnvironment('OMOFUN_SCRIPT');

void main() {
  isolateLinovelibTestStorage();
  MediaKit.ensureInitialized();
  testWidgets(
    'official App API browses, plays and loads episode danmaku',
    (tester) async {
      await tester.runAsync(() async {
        await Storage.init();
        final manager = ExtensionManager.instance;
        await manager.init();
        final extension = await manager.installFromScript(
          await File(scriptPath).readAsString(),
        );
        final service = await manager.ensureLoaded(extension.package);
        expect(await service.channels(), isNotEmpty);
        expect(await service.latest(1, channel: '1'), isNotEmpty);
        expect(await service.latest(2, channel: '1'), isNotEmpty);
        final results = await service.search('新宝可梦', 1);
        final item = results.firstWhere((item) => item.title == '新宝可梦');
        final detail = await service.detail(item.url, title: item.title);
        final group = detail.episodes.firstWhere(
          (group) => group.title == '天堂',
        );
        final watch = AnimeWatch.fromJson(
          await service.watch(group.urls.first.url),
        );
        expect(watch.danmaku?.format, 'extension');
        final rows = await service.danmaku(watch.danmaku!.url, 0, 180);
        expect(rows, isNotEmpty);
        expect(rows.any((row) => row.mode == DanmakuMode.top), isTrue);
        expect(await service.danmaku(watch.danmaku!.url, 600, 780), isNotEmpty);
        final player = Player();
        try {
          await configurePlayerFor(player, 'omofun', watch);
          await player.open(await buildMedia('omofun', watch));
          final duration = await player.stream.duration
              .firstWhere((duration) => duration.inMinutes > 10)
              .timeout(const Duration(seconds: 25));
          expect(duration.inMinutes, greaterThan(10));
          await player.pause();
        } finally {
          await player.dispose();
          service.dispose();
          await Hive.close();
        }
      });
    },
    skip: scriptPath.isEmpty,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
