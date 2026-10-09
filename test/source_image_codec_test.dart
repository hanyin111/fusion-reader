import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/services/source_image_codec.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const url =
      'https://cdn.example/media/photos/220980/00001.png#fusion-jmcomic=220980';

  test('concurrent pages keep decoding after a corrupt response', () async {
    final bytes = img.encodePng(img.Image(width: 2, height: 23));
    final jobs = [
      SourceImageCodec.decode(
        'jmcomic',
        url,
        Uint8List.fromList([1, 2, 3]),
      ).then((_) => false, onError: (Object error) => error is FormatException),
      ...List.generate(
        6,
        (_) => SourceImageCodec.decode(
          'jmcomic',
          url,
          bytes,
        ).then((decoded) => img.decodeImage(decoded)!.height == 23),
      ),
    ];
    expect(await Future.wait(jobs), everyElement(isTrue));
  });

  test(
    'page context is source scoped, path checked, and stripped for HTTP',
    () {
      expect(SourceImageCodec.episodeId('jmcomic', url), 220980);
      expect(SourceImageCodec.requestUrl('jmcomic', url), url.split('#').first);
      expect(SourceImageCodec.episodeId('picacg', url), isNull);
      expect(
        SourceImageCodec.episodeId(
          'jmcomic',
          url.replaceFirst('/220980/', '/220981/'),
        ),
        isNull,
      );
      expect(
        SourceImageCodec.episodeId(
          'jmcomic',
          '/local/page.png#fusion-jmcomic=220980',
        ),
        isNull,
      );
      expect(
        SourceImageCodec.headersFor('jmcomic', null)['Referer'],
        'https://localhost/',
      );
      expect(
        SourceImageCodec.headersFor('jmcomic', {
          'User-Agent': 'custom',
        })['User-Agent'],
        'custom',
      );
      expect(SourceImageCodec.headersFor('picacg', null), isEmpty);
    },
  );

  test('protocol thresholds and GIF bypass are preserved', () {
    expect(SourceImageCodec.sliceCount(220979, '00001.jpg'), 0);
    expect(SourceImageCodec.sliceCount(220980, '00001.jpg'), 10);
    expect(SourceImageCodec.sliceCount(268849, '00001.jpg'), 10);
    expect(SourceImageCodec.sliceCount(500000, '00001.GIF'), 0);
    // Independent precomputed MD5 vectors, checked below against .NET.
    expect(SourceImageCodec.sliceCount(268850, '00001.jpg'), 6);
    expect(SourceImageCodec.sliceCount(421926, '00001.jpg'), 6);
    expect(SourceImageCodec.sliceCount(421927, '00001.jpg'), 8);
  });

  test(
    'reverses stripes with remainder rows without losing pixels or alpha',
    () async {
      final input = img.Image(width: 3, height: 23, numChannels: 4);
      for (var y = 0; y < input.height; y++) {
        for (var x = 0; x < input.width; x++) {
          input.setPixelRgba(x, y, y, x, 42, 200);
        }
      }
      final bytes = img.encodePng(input);
      final restored = img.decodeImage(
        await SourceImageCodec.decode('jmcomic', url, bytes),
      )!;
      const rows = [
        18,
        19,
        20,
        21,
        22,
        16,
        17,
        14,
        15,
        12,
        13,
        10,
        11,
        8,
        9,
        6,
        7,
        4,
        5,
        2,
        3,
        0,
        1,
      ];
      expect(restored.width, 3);
      expect(restored.height, 23);
      for (var y = 0; y < restored.height; y++) {
        for (var x = 0; x < restored.width; x++) {
          final pixel = restored.getPixel(x, y);
          expect([pixel.r, pixel.g, pixel.b, pixel.a], [rows[y], x, 42, 200]);
        }
      }
      expect(
        identical(
          await SourceImageCodec.decode('weebcentral', url, bytes),
          bytes,
        ),
        isTrue,
      );
      expect(
        identical(
          await SourceImageCodec.decode('jmcomic', url.split('#').first, bytes),
          bytes,
        ),
        isTrue,
      );
    },
  );

  test(
    'GIF and old pages pass through; malformed transformed images fail',
    () async {
      final bytes = Uint8List.fromList([1, 2, 3]);
      expect(
        identical(
          await SourceImageCodec.decode(
            'jmcomic',
            url.replaceFirst('.png', '.gif'),
            bytes,
          ),
          bytes,
        ),
        isTrue,
      );
      final oldUrl = url.replaceAll('220980', '220979');
      expect(
        identical(
          await SourceImageCodec.decode('jmcomic', oldUrl, bytes),
          bytes,
        ),
        isTrue,
      );
      await expectLater(
        SourceImageCodec.decode('jmcomic', url, bytes),
        throwsFormatException,
      );
    },
  );
}
