import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/models/app_update.dart';
import 'package:fusion_reader/pages/app_update_page.dart';
import 'package:fusion_reader/services/app_update_api.dart';
import 'package:fusion_reader/services/app_update_controller.dart';
import 'package:fusion_reader/services/app_update_installer.dart';
import 'package:path/path.dart' as p;

Map<String, dynamic> releaseJson({
  String version = '1.5.0',
  List<int> bytes = const [1, 2, 3],
}) => {
  'tag_name': 'v$version',
  'draft': false,
  'prerelease': false,
  'body': '更新内容',
  'assets': [
    for (final name in [
      'FusionReader-$version-windows-x64.zip',
      'FusionReader-$version-android-arm64-v8a.apk',
      'FusionReader-$version-android-armeabi-v7a.apk',
      'FusionReader-ios-unsigned.ipa',
    ])
      <String, dynamic>{
        'name': name,
        'state': 'uploaded',
        'size': bytes.length,
        'digest': 'sha256:${sha256.convert(bytes)}',
        'browser_download_url':
            'https://github.com/hanyin111/fusion-reader/releases/download/v$version/$name',
      },
  ],
};

class UpdateAdapter implements HttpClientAdapter {
  final FutureOr<ResponseBody> Function(RequestOptions request) handler;
  final List<String> requests = [];
  UpdateAdapter(this.handler);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri.toString());
    expect(options.headers['Authorization'], isNull);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

class TestInstaller extends AppUpdateInstaller {
  final UpdateDevice testDevice;
  int installs = 0, discarded = 0, opened = 0;
  bool denyInstall = false;
  Completer<void>? installGate;
  TestInstaller(this.testDevice);
  @override
  Future<UpdateDevice> device() async => testDevice;
  @override
  Future<void> install(PreparedAppUpdate update, UpdateDevice device) async {
    installs++;
    if (denyInstall) {
      throw PlatformException(code: 'permission', message: '未允许安装');
    }
    await installGate?.future;
  }

  @override
  Future<void> discard(PreparedAppUpdate update, UpdateDevice device) async {
    discarded++;
    await super.discard(update, device);
  }

  @override
  Future<void> openRelease(AppUpdateRelease release) async {
    opened++;
  }
}

AppUpdateApi apiFor(UpdateAdapter adapter) =>
    AppUpdateApi(client: Dio()..httpClientAdapter = adapter);
ResponseBody bytesBody(List<int> bytes) =>
    ResponseBody(Stream.value(Uint8List.fromList(bytes)), 200);

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('fusion_app_update_test_');
  });
  tearDown(() async {
    // Each generated test tree is directly inside the explicitly named temp directory.
    expect(p.dirname(root.path), p.normalize(Directory.systemTemp.path));
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'versions compare numerically and ignore platform build-code offsets',
    () {
      expect(
        AppVersion.parse('1.10.0')!.compareTo(AppVersion.parse('1.9.9')!),
        greaterThan(0),
      );
      expect(
        AppVersion.parse('1.4.2+2015')!.compareTo(AppVersion.parse('v1.4.2')!),
        0,
      );
      expect(AppVersion.parse('1.4.3-beta'), isNull);
      expect(AppVersion.parse('bad'), isNull);
    },
  );

  test(
    'selects the installed ABI and never takes a different platform package',
    () {
      expect(
        AppUpdateRelease.parse(
          releaseJson(),
          UpdatePlatform.android,
          abi: 'armeabi-v7a',
        ).asset!.name,
        endsWith('armeabi-v7a.apk'),
      );
      expect(
        AppUpdateRelease.parse(
          releaseJson(),
          UpdatePlatform.windows,
        ).asset!.name,
        endsWith('windows-x64.zip'),
      );
      expect(
        AppUpdateRelease.parse(
          releaseJson(),
          UpdatePlatform.android,
          abi: 'unknown',
        ).asset,
        isNull,
      );
      final raw = releaseJson();
      raw['assets'] = (raw['assets'] as List)
          .where((asset) => (asset['name'] as String).endsWith('.apk'))
          .toList();
      expect(AppUpdateRelease.parse(raw, UpdatePlatform.windows).asset, isNull);
    },
  );

  test(
    'drafts, previews, foreign links and missing checksums cannot install',
    () {
      for (final field in ['draft', 'prerelease']) {
        expect(
          () => AppUpdateRelease.parse({
            ...releaseJson(),
            field: true,
          }, UpdatePlatform.windows),
          throwsFormatException,
        );
      }
      for (final bad in [null, 'md5:abc', 'sha256:short']) {
        final raw = releaseJson();
        (raw['assets'] as List).first['digest'] = bad;
        expect(
          AppUpdateRelease.parse(raw, UpdatePlatform.windows).asset,
          isNull,
        );
      }
      for (final bad in [
        'http://github.com/',
        'https://evil.example/',
        'https://github.com/another/project/releases/',
      ]) {
        final raw = releaseJson();
        (raw['assets'] as List).first['browser_download_url'] = bad;
        expect(
          AppUpdateRelease.parse(raw, UpdatePlatform.windows).asset,
          isNull,
        );
      }
    },
  );

  test(
    'GitHub download redirect is bounded and the bytes must match its digest',
    () async {
      const content = [5, 6, 7];
      final release = AppUpdateRelease.parse(
        releaseJson(bytes: content),
        UpdatePlatform.windows,
      );
      final adapter = UpdateAdapter(
        (request) => request.uri.host == 'github.com'
            ? ResponseBody.fromString(
                '',
                302,
                headers: {
                  'location': [
                    'https://release-assets.githubusercontent.com/test/package',
                  ],
                },
              )
            : bytesBody(content),
      );
      final api = apiFor(adapter);
      final file = File(p.join(root.path, 'package.zip'));
      await api.download(
        release.asset!,
        file,
        cancel: CancelToken(),
        progress: (received, total) {
          expect(received, total);
        },
      );
      expect(await file.readAsBytes(), content);
      expect(adapter.requests.length, 2);
      api.close();
      for (final bytes in [
        [5, 6],
        [5, 6, 8],
        [5, 6, 7, 8],
      ]) {
        final api = apiFor(UpdateAdapter((_) => bytesBody(bytes)));
        await expectLater(
          api.download(
            release.asset!,
            file,
            cancel: CancelToken(),
            progress: (_, _) {},
          ),
          throwsFormatException,
        );
        api.close();
      }
    },
  );

  test('foreign redirects and API rate limits fail visibly', () async {
    final release = AppUpdateRelease.parse(
      releaseJson(),
      UpdatePlatform.windows,
    );
    final adapter = UpdateAdapter(
      (_) => ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': ['https://evil.example/package.zip'],
        },
      ),
    );
    final api = apiFor(adapter);
    await expectLater(
      api.download(
        release.asset!,
        File(p.join(root.path, 'x')),
        cancel: CancelToken(),
        progress: (_, _) {},
      ),
      throwsFormatException,
    );
    expect(adapter.requests.length, 1);
    api.close();
    final limited = apiFor(
      UpdateAdapter((_) => ResponseBody.fromString('', 403)),
    );
    await expectLater(
      limited.latest(UpdatePlatform.windows),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('受限'),
        ),
      ),
    );
    limited.close();
  });

  test(
    'prepares a valid bundle and rejects traversal, device names and links before extraction',
    () async {
      List<int> bundle([ArchiveFile? extra]) {
        final archive = Archive()
          ..add(ArchiveFile.string('fusion_reader.exe', 'new exe'))
          ..add(ArchiveFile.string('flutter_windows.dll', 'new dll'))
          ..add(ArchiveFile.string('data/app.so', 'new aot'));
        if (extra != null) archive.add(extra);
        return ZipEncoder().encode(archive);
      }

      final zip = File(p.join(root.path, 'package.zip'));
      await zip.writeAsBytes(bundle());
      await extractWindowsUpdate(zip.path, p.join(root.path, 'ok'));
      expect(
        await File(p.join(root.path, 'ok', 'data', 'app.so')).readAsString(),
        'new aot',
      );
      for (final name in [
        '../escaped',
        'C:/escaped',
        '/absolute',
        'data/NUL.txt',
        'data/a:',
        'data/trailing.',
      ]) {
        await zip.writeAsBytes(bundle(ArchiveFile.string(name, 'bad')));
        await expectLater(
          extractWindowsUpdate(zip.path, p.join(root.path, 'bad')),
          throwsFormatException,
        );
        expect(await Directory(p.join(root.path, 'bad')).exists(), isFalse);
      }
      await zip.writeAsBytes(
        bundle(ArchiveFile.string('data/link', '../outside')..mode = 0xa1ff),
      );
      await expectLater(
        extractWindowsUpdate(zip.path, p.join(root.path, 'bad')),
        throwsFormatException,
      );
    },
  );

  test(
    'download/install state preserves data, allows permission retry and cleans cancelled jobs',
    () async {
      final installer = TestInstaller(
        UpdateDevice(UpdatePlatform.android, abi: 'arm64-v8a', cache: root),
      );
      final adapter = UpdateAdapter(
        (request) => request.uri.host == 'api.github.com'
            ? ResponseBody.fromString(jsonEncode(releaseJson()), 200)
            : bytesBody([1, 2, 3]),
      );
      final controller = AppUpdateController(
        api: apiFor(adapter),
        installer: installer,
        versionLoader: () async => '1.4.2',
      );
      await controller.check();
      expect(controller.phase, AppUpdatePhase.available);
      await controller.download();
      expect(controller.phase, AppUpdatePhase.ready);
      installer.denyInstall = true;
      await controller.install();
      expect(controller.error, '未允许安装');
      expect(controller.phase, AppUpdatePhase.ready);
      installer.denyInstall = false;
      await controller.install();
      expect(installer.installs, 2);
      expect(controller.message, contains('系统安装界面'));
      controller.dispose();
      expect(
        (await root.list().toList()).length,
        1,
      ); // The system installer still needs its APK.
    },
  );

  test(
    'cancelled download never prepares or installs a partial package',
    () async {
      final installer = TestInstaller(
        UpdateDevice(UpdatePlatform.android, abi: 'arm64-v8a', cache: root),
      );
      late AppUpdateController controller;
      final adapter = UpdateAdapter((request) {
        if (request.uri.host == 'api.github.com') {
          return ResponseBody.fromString(jsonEncode(releaseJson()), 200);
        }
        controller.cancelDownload();
        return bytesBody([1]);
      });
      controller = AppUpdateController(
        api: apiFor(adapter),
        installer: installer,
        versionLoader: () async => '1.4.2',
      );
      await controller.check();
      await controller.download();
      expect(controller.phase, AppUpdatePhase.available);
      expect(controller.error, isEmpty);
      expect(installer.installs, 0);
      expect(await root.list().toList(), isEmpty);
      controller.dispose();
    },
  );

  test(
    'checking again cannot replace a package while installation is pending',
    () async {
      final installer = TestInstaller(
        UpdateDevice(UpdatePlatform.android, abi: 'arm64-v8a', cache: root),
      );
      final adapter = UpdateAdapter(
        (request) => request.uri.host == 'api.github.com'
            ? ResponseBody.fromString(jsonEncode(releaseJson()), 200)
            : bytesBody([1, 2, 3]),
      );
      final controller = AppUpdateController(
        api: apiFor(adapter),
        installer: installer,
        versionLoader: () async => '1.4.2',
      );
      await controller.check();
      await controller.download();
      installer.installGate = Completer<void>();
      final installing = controller.install();
      expect(controller.phase, AppUpdatePhase.installing);
      final requests = adapter.requests.length;
      await controller.check();
      expect(controller.phase, AppUpdatePhase.installing);
      expect(adapter.requests.length, requests);
      installer.installGate!.complete();
      await installing;
      expect(controller.phase, AppUpdatePhase.ready);
      controller.dispose();
    },
  );

  testWidgets(
    'iOS shows side-loading guidance and no automatic install action',
    (tester) async {
      final installer = TestInstaller(const UpdateDevice(UpdatePlatform.ios));
      final controller = AppUpdateController(
        api: apiFor(
          UpdateAdapter(
            (_) => ResponseBody.fromString(jsonEncode(releaseJson()), 200),
          ),
        ),
        installer: installer,
        versionLoader: () async => '1.4.2',
      );
      await tester.pumpWidget(
        MaterialApp(home: AppUpdatePage(controller: controller)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('签名或侧载'), findsOneWidget);
      expect(find.text('下载更新'), findsNothing);
      await tester.tap(find.text('打开发布页'));
      await tester.pumpAndSettle();
      expect(installer.opened, 1);
      expect(installer.installs, 0);
    },
  );
}
