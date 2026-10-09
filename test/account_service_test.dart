import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/models.dart';
import 'package:fusion_reader/services/account_api.dart';
import 'package:fusion_reader/services/account_service.dart';
import 'package:fusion_reader/services/library_backup.dart';

import 'history_test.dart' show novel, comic, progress;

LibraryBackup snapshot({
  List<MediaItem> favorites = const [],
  List<HistoryRecord> history = const [],
}) => LibraryBackup.decode(
  utf8.encode(
    jsonEncode({
      'format': 'FusionReader.library',
      'schemaVersion': 1,
      'exportedAt': '2026-10-09T00:00:00Z',
      'favorites': favorites.map((e) => e.toJson()).toList(),
      'history': history.map((e) => e.toJson()).toList(),
    }),
  ),
);

AccountSession loginSession([String name = 'reader']) => AccountSession(
  userId: name,
  username: name,
  token: 'abcdefghijklmnopqrstuvwxyz0123456789_ABCD',
  expiresAt: DateTime.now().toUtc().add(const Duration(days: 30)),
);

class MemorySessions implements AccountSessionStore {
  AccountSession? value;
  bool failWrite = false;
  bool failRead = false;
  bool failClear = false;
  bool ignoreWrite = false;
  @override
  Future<AccountSession?> read() async {
    if (failRead) throw StateError('unavailable');
    return value;
  }

  @override
  Future<void> write(AccountSession session) async {
    if (failWrite) throw StateError('unavailable');
    if (!ignoreWrite) value = session;
  }

  @override
  Future<void> clear() async {
    if (failClear) throw StateError('unavailable');
    value = null;
  }
}

class MemoryLibrary implements AccountLibraryStore {
  LibraryBackup value = snapshot();
  final ancestors = <String, AccountSyncState>{};
  int applies = 0;
  @override
  LibraryBackup capture() => value;
  @override
  Future<void> apply(LibraryBackup snapshot) async {
    value = snapshot;
    applies++;
  }

  @override
  Future<AccountSyncState?> baseline(String owner) async => ancestors[owner];
  @override
  Future<void> saveBaseline(String owner, AccountSyncState state) async {
    ancestors[owner] = state;
  }
}

class MemoryApi implements AccountApi {
  @override
  String serviceId = 'https://sync.example.test';
  @override
  bool configured = true;
  LibraryBackup cloud = snapshot();
  int revision = 0;
  int uploads = 0;
  int logins = 0;
  int conflicts = 0;
  AccountException? failure;
  Future<void> Function()? duringUpload;
  Future<void> Function()? duringDownload;
  String? activation;
  String? username;
  @override
  Future<AccountSession> authenticate(
    String username,
    String password, {
    String? activationCode,
  }) async {
    logins++;
    this.username = username;
    activation = activationCode;
    if (failure != null) throw failure!;
    return loginSession(username);
  }

  @override
  Future<CloudLibrary> download(String token) async {
    if (duringDownload != null) await duringDownload!();
    if (failure != null) throw failure!;
    return CloudLibrary(revision, cloud);
  }

  @override
  Future<int> upload(
    String token,
    int expectedRevision,
    LibraryBackup snapshot,
  ) async {
    uploads++;
    if (duringUpload != null) await duringUpload!();
    if (failure != null) throw failure!;
    if (conflicts > 0) {
      conflicts--;
      cloud = LibraryBackup.reconcile(local: cloud, remote: libraryWithComic());
      revision++;
    }
    if (expectedRevision != revision) {
      throw const AccountException('conflict', conflict: true);
    }
    cloud = snapshot;
    return ++revision;
  }

  LibraryBackup libraryWithComic() =>
      snapshot(favorites: [comic], history: [progress(comic, 200)]);
  @override
  Future<void> logout(String token) async {
    if (failure != null) throw failure!;
  }
}

void main() {
  late MemoryApi api;
  late MemorySessions sessions;
  late MemoryLibrary library;
  late AccountService service;
  setUp(() {
    api = MemoryApi();
    sessions = MemorySessions();
    library = MemoryLibrary();
    service = AccountService(api: api, sessions: sessions, library: library);
  });
  tearDown(() => service.dispose());
  Future<void> login() async {
    expect(await service.authenticate('reader', 'password123'), isTrue);
  }

  test(
    'registration normalizes names and passes a one-time code, invalid input never calls API',
    () async {
      expect(
        await service.authenticate('x', 'short', activationCode: ''),
        isFalse,
      );
      expect(api.logins, 0);
      expect(
        await service.authenticate(
          ' READER_1 ',
          'password123',
          activationCode: ' INVITE ',
        ),
        isTrue,
      );
      expect(api.username, 'reader_1');
      expect(api.activation, 'INVITE');
      expect(sessions.value!.username, 'reader_1');
      expect(library.applies, 0);
    },
  );

  test(
    'upload replaces cloud exactly without writing back remote-only books',
    () async {
      library.value = snapshot(
        favorites: [novel],
        history: [progress(novel, 100).copyWith(textOffset: 731)],
      );
      api.cloud = snapshot(favorites: [comic], history: [progress(comic, 200)]);
      await login();
      expect(await service.uploadToCloud(), isTrue);
      expect(library.value.favorites.map((e) => e.key), [novel.key]);
      expect(api.cloud.favorites.map((e) => e.key), [novel.key]);
      expect(api.cloud.history.single.textOffset, 731);
      expect(library.applies, 0);
      final other = MemoryLibrary()..value = snapshot(favorites: [comic]);
      final otherService = AccountService(
        api: api,
        sessions: MemorySessions(),
        library: other,
      );
      await otherService.authenticate('reader', 'password123');
      expect(await otherService.downloadToLocal(), isTrue);
      expect(
        other.value.history.firstWhere((e) => e.key == novel.key).textOffset,
        731,
      );
      expect(
        other.value.history.firstWhere((e) => e.key == novel.key).timestamp,
        100,
      );
      expect(other.value.favorites.map((e) => e.key), [novel.key]);
      expect(api.uploads, 1);
      otherService.dispose();
    },
  );

  test(
    'deleted books stay deleted after upload then download, including an empty shelf',
    () async {
      library.value = snapshot(
        favorites: [novel, comic],
        history: [progress(novel, 10), progress(comic, 20)],
      );
      await login();
      await service.uploadToCloud();
      final otherLibrary = MemoryLibrary();
      final other = AccountService(
        api: api,
        sessions: MemorySessions(),
        library: otherLibrary,
      );
      await other.authenticate('reader', 'password123');
      await other.downloadToLocal();
      library.value = snapshot(
        favorites: [comic],
        history: [progress(comic, 20)],
      );
      expect(await service.uploadToCloud(), isTrue);
      expect(await other.downloadToLocal(), isTrue);
      expect(otherLibrary.value.favorites.map((e) => e.key), [comic.key]);
      expect(otherLibrary.value.history.map((e) => e.key), [comic.key]);
      otherLibrary.value = snapshot();
      await other.uploadToCloud();
      await service.downloadToLocal();
      expect(library.value.favorites, isEmpty);
      expect(library.value.history, isEmpty);
      other.dispose();
    },
  );

  test(
    'revision conflict stops upload without silently merging or retrying',
    () async {
      await login();
      library.value = snapshot(favorites: [novel]);
      api.conflicts = 1;
      expect(await service.uploadToCloud(), isFalse);
      expect(api.uploads, 1);
      expect(api.cloud.favorites.map((e) => e.key), [comic.key]);
      expect(library.value.favorites.map((e) => e.key), [novel.key]);
      expect(service.error, contains('其他设备'));
      expect(library.ancestors, isEmpty);
      expect(await service.uploadToCloud(), isTrue);
      expect(api.cloud.favorites.map((e) => e.key), [novel.key]);
    },
  );

  test(
    'edits during an upload are retained locally and reach the next upload',
    () async {
      await login();
      library.value = snapshot(
        favorites: [novel],
        history: [progress(novel, 10)],
      );
      api.duringUpload = () async {
        library.value = snapshot(
          favorites: [comic],
          history: [progress(novel, 40).copyWith(textOffset: 920)],
        );
      };
      expect(await service.uploadToCloud(), isTrue);
      expect(library.value.favorites.map((e) => e.key), [comic.key]);
      expect(library.value.history.single.textOffset, 920);
      expect(api.cloud.favorites.map((e) => e.key), [novel.key]);
      api.duringUpload = null;
      expect(await service.uploadToCloud(), isTrue);
      expect(api.cloud.favorites.map((e) => e.key), [comic.key]);
      expect(api.cloud.history.single.textOffset, 920);
    },
  );

  test('failed upload never changes local data or accepted baseline', () async {
    await login();
    library.value = snapshot(favorites: [novel]);
    api.duringUpload = () async {
      throw const AccountException('network failed');
    };
    final before = library.value.encode();
    expect(await service.uploadToCloud(), isFalse);
    expect(library.value.encode(), before);
    expect(library.applies, 0);
    expect(library.ancestors, isEmpty);
    expect(service.lastSync, isNull);
  });

  test('download only replaces local data and never uploads', () async {
    await login();
    library.value = snapshot(favorites: [novel]);
    api.cloud = snapshot(favorites: [comic], history: [progress(comic, 200)]);
    expect(await service.downloadToLocal(), isTrue);
    expect(library.value.favorites.map((e) => e.key), [comic.key]);
    expect(api.cloud.favorites.map((e) => e.key), [comic.key]);
    expect(api.uploads, 0);
    api.cloud = snapshot();
    expect(await service.downloadToLocal(), isTrue);
    expect(library.value.favorites, isEmpty);
    expect(library.value.history, isEmpty);
    expect(api.uploads, 0);
  });

  test(
    'failed download or concurrent local edits cannot erase local data',
    () async {
      await login();
      library.value = snapshot(favorites: [novel]);
      api.failure = const AccountException('offline');
      expect(await service.downloadToLocal(), isFalse);
      expect(library.value.favorites.single.key, novel.key);
      api.failure = null;
      api.cloud = snapshot();
      api.duringDownload = () async {
        library.value = snapshot(favorites: [novel, comic]);
      };
      expect(await service.downloadToLocal(), isFalse);
      expect(library.value.favorites.length, 2);
      expect(service.error, contains('本机数据发生变化'));
      expect(library.applies, 0);
      expect(api.uploads, 0);
    },
  );

  test(
    'secure storage failures cannot create an apparently successful login',
    () async {
      sessions.failRead = true;
      sessions.failWrite = true;
      expect(await service.authenticate('reader', 'password123'), isFalse);
      expect(service.session, isNull);
      expect(service.initialized, isTrue);
      expect(service.error, contains('安全'));
      sessions.failWrite = false;
      sessions.failRead = false;
      expect(await service.authenticate('reader', 'password123'), isTrue);
    },
  );

  test(
    'an OS write that silently fails cannot claim login success after registration',
    () async {
      sessions.ignoreWrite = true;
      expect(
        await service.authenticate(
          'reader',
          'password123',
          activationCode: 'INVITE',
        ),
        isFalse,
      );
      expect(service.session, isNull);
      expect(service.error, contains('账号已注册'));
    },
  );

  test(
    '401 or an expired saved session clears login but preserves library',
    () async {
      await login();
      library.value = snapshot(favorites: [novel]);
      api.failure = const AccountException('expired', expired: true);
      expect(await service.uploadToCloud(), isFalse);
      expect(service.session, isNull);
      expect(sessions.value, isNull);
      expect(library.value.favorites.single.key, novel.key);
      final expired = MemorySessions()
        ..value = AccountSession(
          userId: 'reader',
          username: 'reader',
          token: loginSession().token,
          expiresAt: DateTime.now().subtract(const Duration(days: 1)),
        );
      final restored = AccountService(
        api: api,
        sessions: expired,
        library: library,
      );
      await restored.initialize();
      expect(restored.session, isNull);
      expect(expired.value, isNull);
      restored.dispose();
    },
  );

  test(
    'offline logout removes token while failed clear retains session for retry',
    () async {
      await login();
      sessions.failClear = true;
      expect(await service.logout(), isFalse);
      expect(service.session, isNotNull);
      sessions.failClear = false;
      api.failure = const AccountException('offline');
      expect(await service.logout(), isTrue);
      expect(service.session, isNull);
      expect(sessions.value, isNull);
    },
  );

  test(
    'sync prevents concurrent account changes and duplicate requests',
    () async {
      await login();
      final gate = Completer<void>();
      api.duringUpload = () => gate.future;
      final syncing = service.uploadToCloud();
      await Future<void>.delayed(Duration.zero);
      expect(service.busy, isTrue);
      expect(await service.logout(), isFalse);
      expect(await service.authenticate('other', 'password123'), isFalse);
      expect(await service.uploadToCloud(), isFalse);
      gate.complete();
      expect(await syncing, isTrue);
      expect(api.uploads, 1);
    },
  );

  test(
    'baseline is scoped to both service and account, never used for a different account',
    () async {
      await login();
      library.value = snapshot(favorites: [novel]);
      await service.uploadToCloud();
      await service.logout();
      api.cloud = snapshot();
      await service.authenticate('other', 'password123');
      await service.uploadToCloud();
      expect(api.cloud.favorites.single.key, novel.key);
      expect(library.ancestors.length, 2);
      expect(
        library.ancestors.values.every(
          (e) => !e.snapshot.encode().contains(loginSession().token),
        ),
        isTrue,
      );
      await service.logout();
      api.serviceId = 'https://new.example.test';
      api.cloud = snapshot();
      await login();
      await service.uploadToCloud();
      expect(api.cloud.favorites.single.key, novel.key);
      expect(library.ancestors.length, 3);
    },
  );
}
