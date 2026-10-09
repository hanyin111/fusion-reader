import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/services/account_api.dart';
import 'package:fusion_reader/services/account_service.dart';

import 'account_service_test.dart' show MemoryLibrary, MemorySessions, snapshot;
import 'history_test.dart' show novel, comic, progress;

void main() {
  final url = Platform.environment['FUSION_LIVE_URL'];
  final code = Platform.environment['FUSION_LIVE_INVITE'];
  test(
    'deployment accepts two clients over verified HTTPS',
    () async {
      final api = HttpAccountApi(baseUrl: url!);
      final username = 'deploy_${DateTime.now().microsecondsSinceEpoch}';
      final password = base64Url.encode(
        List.generate(24, (_) => Random.secure().nextInt(256)),
      );
      final first = MemoryLibrary()
        ..value = snapshot(
          favorites: [novel],
          history: [progress(novel, 100).copyWith(textOffset: 731)],
        );
      final second = MemoryLibrary()
        ..value = snapshot(favorites: [comic], history: [progress(comic, 200)]);
      final one = AccountService(
        api: api,
        sessions: MemorySessions(),
        library: first,
      );
      final two = AccountService(
        api: api,
        sessions: MemorySessions(),
        library: second,
      );
      try {
        expect(
          await one.authenticate(username, password, activationCode: code),
          isTrue,
          reason: one.error,
        );
        // The operator uses this opaque id to remove only the disposable probe.
        stdout.writeln('FUSION_DEPLOY_PROBE=${one.session!.userId}');
        expect(await one.uploadToCloud(), isTrue, reason: one.error);
        expect(
          await two.authenticate(username, password),
          isTrue,
          reason: two.error,
        );
        expect(await two.downloadToLocal(), isTrue, reason: two.error);
        expect(second.value.favorites.map((e) => e.key), [novel.key]);
        second.value = snapshot(
          favorites: [novel, comic],
          history: [...second.value.history, progress(comic, 200)],
        );
        expect(await two.uploadToCloud(), isTrue, reason: two.error);
        expect(await one.downloadToLocal(), isTrue, reason: one.error);
        expect(
          first.value.favorites.map((e) => e.key),
          containsAll([novel.key, comic.key]),
        );
        expect(
          second.value.history.firstWhere((e) => e.key == novel.key).textOffset,
          731,
        );
        second.value = snapshot(
          favorites: [comic],
          history: [progress(comic, 200)],
        );
        expect(await two.uploadToCloud(), isTrue, reason: two.error);
        expect(await one.downloadToLocal(), isTrue, reason: one.error);
        expect(first.value.favorites.map((e) => e.key), [comic.key]);
        expect(first.value.history.map((e) => e.key), [comic.key]);
        final token = two.session!.token;
        expect(await two.logout(), isTrue);
        await expectLater(
          api.download(token),
          throwsA(
            isA<AccountException>().having((e) => e.expired, 'expired', true),
          ),
        );
        expect(await one.logout(), isTrue);
      } finally {
        one.dispose();
        two.dispose();
      }
    },
    skip: url == null || code == null
        ? 'Explicit disposable activation code required'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
