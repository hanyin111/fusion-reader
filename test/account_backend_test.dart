import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/services/account_api.dart';
import 'package:fusion_reader/services/account_service.dart';

import 'account_service_test.dart' show MemoryLibrary, MemorySessions, snapshot;
import 'history_test.dart' show novel, comic, progress;

void main() {
  test(
    'real SQLite backend works with two Flutter clients and one-time registration',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'fusion_sync_protocol_',
      );
      Process? process;
      AccountService? one;
      AccountService? two;
      StreamSubscription<String>? errors;
      try {
        process = await Process.start('python', [
          '${Directory.current.path}/server/test_fixture.py',
          '${root.path}/library.sqlite3',
        ]);
        // The fixture binds only 127.0.0.1 and creates an ephemeral test database.
        errors = process.stderr.transform(utf8.decoder).listen((_) {});
        final line = await process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 15));
        final fixture = jsonDecode(line) as Map;
        final api = HttpAccountApi(
          baseUrl: 'http://127.0.0.1:${fixture['port']}',
          allowLocalHttp: true,
        );
        final first = MemoryLibrary()
          ..value = snapshot(
            favorites: [novel],
            history: [progress(novel, 100).copyWith(textOffset: 731)],
            readerSettings: {
              'ios': {'novel_fontName': '衬线', 'novel_fontSize': 26},
            },
          );
        one = AccountService(
          api: api,
          sessions: MemorySessions(),
          library: first,
        );
        expect(
          await one.authenticate(
            'reader',
            'fixture-password',
            activationCode: fixture['activationCode'] as String,
          ),
          isTrue,
          reason: one.error,
        );
        await expectLater(
          api.authenticate(
            'other',
            'fixture-password',
            activationCode: fixture['activationCode'] as String,
          ),
          throwsA(
            isA<AccountException>().having(
              (e) => e.message,
              'message',
              contains('激活码'),
            ),
          ),
        );
        expect(await one.uploadToCloud(), isTrue, reason: one.error);
        final second = MemoryLibrary()
          ..value = snapshot(
            favorites: [comic],
            history: [progress(comic, 200)],
          );
        two = AccountService(
          api: api,
          sessions: MemorySessions(),
          library: second,
        );
        expect(
          await two.authenticate('reader', 'fixture-password'),
          isTrue,
          reason: two.error,
        );
        expect(await two.downloadToLocal(), isTrue, reason: two.error);
        expect(second.value.favorites.map((e) => e.key), [novel.key]);
        expect(second.value.readerSettings['ios']!['novel_fontSize'], 26);
        expect(
          second.value.history.firstWhere((e) => e.key == novel.key).textOffset,
          731,
        );
        second.value = snapshot(
          favorites: [novel, comic],
          history: [...second.value.history, progress(comic, 200)],
          readerSettings: {
            'android': {'mangaWebtoon': true},
          },
        );
        expect(await two.uploadToCloud(), isTrue, reason: two.error);
        expect(await one.downloadToLocal(), isTrue, reason: one.error);
        expect(
          first.value.readerSettings.keys,
          containsAll(['ios', 'android']),
        );
        expect(first.value.readerSettings['ios']!['novel_fontName'], '衬线');
        expect(
          first.value.favorites.map((e) => e.key),
          containsAll([novel.key, comic.key]),
        );
        second.value = snapshot(
          favorites: [comic],
          history: [progress(comic, 200)],
        );
        expect(await two.uploadToCloud(), isTrue, reason: two.error);
        expect(await one.downloadToLocal(), isTrue, reason: one.error);
        expect(first.value.favorites.map((e) => e.key), [comic.key]);
        expect(first.value.history.map((e) => e.key), [comic.key]);
        final oldToken = two.session!.token;
        expect(await two.logout(), isTrue);
        await expectLater(
          api.download(oldToken),
          throwsA(
            isA<AccountException>().having((e) => e.expired, 'expired', isTrue),
          ),
        );
        expect(await one.uploadToCloud(), isTrue, reason: one.error);
      } finally {
        one?.dispose();
        two?.dispose();
        process?.kill();
        if (process != null) {
          await process.exitCode.timeout(const Duration(seconds: 5));
        }
        await errors?.cancel();
        final temporaryRoot = await Directory.systemTemp.resolveSymbolicLinks();
        final resolved = await root.resolveSymbolicLinks();
        final prefix = '$temporaryRoot${Platform.pathSeparator}';
        if (!resolved.toLowerCase().startsWith(prefix.toLowerCase()) ||
            !root.path
                .split(Platform.pathSeparator)
                .last
                .startsWith('fusion_sync_protocol_')) {
          throw StateError(
            'Refusing to delete a path outside the test directory',
          );
        }
        await root.delete(recursive: true);
      }
    },
  );
}
