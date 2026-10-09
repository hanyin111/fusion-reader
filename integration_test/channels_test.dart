import 'repository_fixture.dart';
// Verifies the browse-channel feature against a source that needs no account.
//
// PicACG also publishes channels (sorts, leaderboards, live categories) but
// those need the user's own credentials, so yhdm is what can be proven here.
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/services/extension_manager.dart';
import 'package:fusion_reader/services/storage.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'browse channels return distinct listings',
    (tester) async {
      await tester.runAsync(() async {
        await Storage.init();
        await ExtensionManager.instance.init();
        await installRepositoryFixtures(['yhdm']);

        final service = ExtensionManager.instance.byPackage('yhdm');
        expect(service, isNotNull, reason: 'yhdm 扩展未加载');

        final channels = await service!.channels();
        print('\n===== CHANNELS: ${channels.length} 个 =====');
        expect(channels.length, greaterThan(3), reason: 'channels() 返回过少');

        final samples = <String, List<String>>{};
        // Probe a spread of channel kinds: all, a region and a genre.
        for (final channel in [channels.first, channels[1], channels.last]) {
          final items = await service.latest(1, channel: channel.key);
          print(
            '  [${channel.title}] key="${channel.key}" -> ${items.length} 条'
            '${items.isEmpty ? "" : "，例: ${items.first.title}"}',
          );
          expect(items, isNotEmpty, reason: '频道 "${channel.title}" 返回空列表');
          samples[channel.title] = items.map((e) => e.title).toList();
        }

        // A channel that filters nothing would make the feature pointless.
        final all = samples[channels.first.title]!.toSet();
        final filtered = samples[channels.last.title]!.toSet();
        final overlap = all.intersection(filtered).length;
        print(
          '  「${channels.first.title}」与「${channels.last.title}」重合 $overlap 条',
        );
        print('=============================');
        expect(
          overlap == all.length && all.length == filtered.length,
          isFalse,
          reason: '频道筛选无效：两个频道返回了完全相同的列表',
        );
      });
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
