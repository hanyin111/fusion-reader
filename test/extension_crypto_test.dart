import 'package:flutter_test/flutter_test.dart';
import 'package:fusion_reader/services/extension_crypto.dart';

void main() {
  // Vectors generated independently with .NET AES / ECB / PKCS7.
  test(
    'AES text decoding preserves JSON and Unicode with 128/256 bit keys',
    () {
      const plain = '{"ok":true,"text":"中文 🌸"}';
      expect(
        decryptAesEcb(
          'i4DWxx8pR1+mo4Z3+NtQXeAxp4lw53xKlrS1SdVYdOs3ciLgYakkxZHNnCfqFj7U',
          '0123456789abcdef',
        ),
        plain,
      );
      expect(
        decryptAesEcb(
          '3nIGD8S8JDbbEXQdweNnj+exvr03VqTTw2W0xjoFvuyKo2JB/ejfBU3DJcbGlbie',
          '0123456789abcdef0123456789abcdef',
        ),
        plain,
      );
    },
  );

  test('invalid ciphertext and every padding byte are checked', () {
    const key = '0123456789abcdef0123456789abcdef';
    for (final value in [
      '',
      'not base64',
      'YWJj',
      '0CBlfet6NfJ0i+rAk/uGxA==',
    ]) {
      expect(() => decryptAesEcb(value, key), throwsFormatException);
    }
    expect(() => decryptAesEcb('YWJj', 'short'), throwsFormatException);
  });
}
