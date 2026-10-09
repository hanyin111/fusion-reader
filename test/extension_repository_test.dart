import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/services/extension_repository.dart';

const script = '''
// ==MiruExtension==
// @name Fixture
// @package fixture
// @version v1.2.0
// @type fikushon
// ==/MiruExtension==
export default class extends Extension {}
''';

Map<String, dynamic> entryFor(String source) => {
  'package': 'fixture',
  'name': 'Fixture',
  'version': 'v1.2.0',
  'type': 'novel',
  'lang': 'zh',
  'minAppVersion': '1.4.0',
  'url': 'scripts/fixture.js',
  'size': utf8.encode(source).length,
  'sha256': sha256.convert(utf8.encode(source)).toString(),
};

class MemoryAdapter implements HttpClientAdapter {
  final Map<String, List<int>> files;
  final List<String> requests = [];
  MemoryAdapter(this.files);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri.toString());
    final bytes = files[options.uri.toString()];
    return ResponseBody(
      Stream.value(Uint8List.fromList(bytes ?? [])),
      bytes == null ? 404 : 200,
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  final index = Uri.parse('https://example.test/plugins/index.json');
  RepositoryExtension entry([Map<String, dynamic>? values]) =>
      RepositoryExtension.parse(values ?? entryFor(script), index);

  test('relative script URL resolves under the selected repository', () {
    expect(
      entry().url.toString(),
      'https://example.test/plugins/scripts/fixture.js',
    );
    expect(entry().verify(utf8.encode(script)), script);
  });

  test(
    'damaged downloads and mismatched metadata are rejected before execution',
    () {
      expect(
        () => entry().verify(utf8.encode('$script ')),
        throwsFormatException,
      );
      final changed = script.replaceFirst('@package fixture', '@package other');
      expect(
        () => entry(entryFor(changed)).verify(utf8.encode(changed)),
        throwsFormatException,
      );
      expect(
        () => entry({
          ...entryFor(script),
          'name': 'Wrong',
        }).verify(utf8.encode(script)),
        throwsFormatException,
      );
    },
  );

  test(
    'updates compare numerical versions and never downgrade newer scripts',
    () {
      expect(compareExtensionVersions('v1.10.0', '1.2.9'), greaterThan(0));
      expect(entry().hasUpdate(script), isFalse);
      expect(
        entry().hasUpdate(script.replaceFirst('v1.2.0', 'v1.1.9')),
        isTrue,
      );
      expect(
        entry().hasUpdate(script.replaceFirst('v1.2.0', 'v1.3.0')),
        isFalse,
      );
      expect(entry().hasUpdate('$script\n// corrected implementation'), isTrue);
      expect(
        entry().hasUpdate(
          script.replaceFirst('@package fixture', '@package other'),
        ),
        isFalse,
      );
    },
  );

  test('required app version blocks unsupported plugins', () {
    expect(entry().supports('1.3.8'), isFalse);
    expect(entry().supports('1.4.0'), isTrue);
    expect(entry().supports('1.10.0'), isTrue);
    expect(entry().supports('invalid'), isFalse);
  });

  test('manifest rejects duplicate identifiers and unknown schema', () {
    final catalog = {
      'schemaVersion': 1,
      'name': 'Fixtures',
      'extensions': [entryFor(script)],
    };
    expect(ExtensionCatalog.parse(catalog, index).extensions, hasLength(1));
    expect(
      () => ExtensionCatalog.parse({...catalog, 'schemaVersion': 2}, index),
      throwsFormatException,
    );
    expect(
      () => ExtensionCatalog.parse({
        ...catalog,
        'extensions': [entryFor(script), entryFor(script)],
      }, index),
      throwsFormatException,
    );
  });

  test('manifest rejects untrusted URL forms and malformed metadata', () {
    for (final value in [
      'http://example.test/index.json',
      'https://user:pass@example.test/index.json',
      'https://example.test/index.json#fragment',
    ]) {
      expect(() => repositoryUri(value), throwsFormatException);
    }
    for (final change in <Map<String, dynamic>>[
      {'url': 'http://example.test/fixture.js'},
      {'size': ExtensionRepository.maxScriptBytes + 1},
      {'sha256': 'broken'},
      {'type': 'unknown'},
      {'version': 'next'},
      {'package': '../fixture'},
    ]) {
      expect(
        () => entry({...entryFor(script), ...change}),
        throwsFormatException,
      );
    }
  });

  test('fetch and install verify the actual response bytes', () async {
    final adapter = MemoryAdapter({
      index.toString(): utf8.encode(
        jsonEncode({
          'schemaVersion': 1,
          'name': 'Fixtures',
          'extensions': [entryFor(script)],
        }),
      ),
      'https://example.test/plugins/scripts/fixture.js': utf8.encode(script),
    });
    final client = Dio()..httpClientAdapter = adapter;
    final repository = ExtensionRepository(
      url: index.toString(),
      client: client,
    );
    final catalog = await repository.fetch();
    expect(await repository.download(catalog.extensions.single), script);
    expect(adapter.requests, [index.toString(), entry().url.toString()]);
    adapter.files[entry().url.toString()] = utf8.encode('$script\n');
    await expectLater(
      repository.download(catalog.extensions.single),
      throwsFormatException,
    );
    client.close();
  });

  test('stream size limit and missing files produce errors', () async {
    final adapter = MemoryAdapter({
      index.toString(): List.filled(512 * 1024 + 1, 32),
    });
    final client = Dio()..httpClientAdapter = adapter;
    final repository = ExtensionRepository(
      url: index.toString(),
      client: client,
    );
    await expectLater(repository.fetch(), throwsFormatException);
    await expectLater(
      repository.downloadUrl('https://example.test/missing.js'),
      throwsA(isA<DioException>()),
    );
    client.close();
  });
}
