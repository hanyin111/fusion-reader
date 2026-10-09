import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';

/// One shared decoder for encrypted text APIs on QuickJS and JavaScriptCore.
String decryptAesEcb(String ciphertext, String key) {
  final keyBytes = Uint8List.fromList(utf8.encode(key));
  if (![16, 24, 32].contains(keyBytes.length)) {
    throw const FormatException('AES 密钥长度不正确');
  }
  final encrypted = base64Decode(ciphertext.trim());
  if (encrypted.isEmpty || encrypted.length % 16 != 0) {
    throw const FormatException('加密响应长度不正确');
  }
  final aes = AESEngine()..init(false, KeyParameter(keyBytes));
  final plain = Uint8List(encrypted.length);
  for (var offset = 0; offset < encrypted.length; offset += 16) {
    aes.processBlock(encrypted, offset, plain, offset);
  }
  final padding = plain.last;
  if (padding < 1 ||
      padding > 16 ||
      plain.skip(plain.length - padding).any((byte) => byte != padding)) {
    throw const FormatException('加密响应填充不正确');
  }
  return utf8.decode(plain.sublist(0, plain.length - padding));
}
