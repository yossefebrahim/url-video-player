import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vp/services/hls_key_decryptor.dart';

/// Ground-truth vectors captured by running the ORIGINAL app's real native
/// `libnext.so` (`HlsKeyDecryptor.decryptNative`) on-device. If these fail, the
/// pure-Dart port has diverged from the binary it reimplements.
///
/// The vectors are the real decryption keys for these streams, so they live in
/// the **gitignored `.env`** (`HLS_KEY_TEST_VECTORS`, `blobHex:keyHex` pairs) —
/// never committed. See `.env.example`. Absent `.env`, this one test is skipped;
/// the rest of the suite still runs.
List<(String, String)> _loadVectors() {
  final file = File('.env');
  if (!file.existsSync()) return const [];
  for (final line in file.readAsLinesSync()) {
    final t = line.trim();
    if (!t.startsWith('HLS_KEY_TEST_VECTORS=')) continue;
    final value = t.substring('HLS_KEY_TEST_VECTORS='.length).trim();
    if (value.isEmpty) return const [];
    return [
      for (final pair in value.split(','))
        if (pair.contains(':'))
          (pair.split(':')[0].trim(), pair.split(':')[1].trim())
    ];
  }
  return const [];
}

Uint8List _fromHex(String h) => Uint8List.fromList([
      for (var i = 0; i < h.length; i += 2)
        int.parse(h.substring(i, i + 2), radix: 16)
    ]);

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Rebuilds the `#EXT-X-KEY` `data:` URI the streams carry from a raw blob:
/// `data:…;base64, base64("ENC:" + base64(blob))`.
String _encDataUri(String blobHex) {
  final inner = base64.encode(_fromHex(blobHex));
  return 'data:text/plain;base64,${base64.encode(ascii.encode('ENC:$inner'))}';
}

void main() {
  group('HlsKeyDecryptor.keyFromUri', () {
    final vectors = _loadVectors();

    test('unwraps ENC: data-URI keys to the real 16-byte AES key', () {
      if (vectors.isEmpty) {
        markTestSkipped('no HLS_KEY_TEST_VECTORS in .env (see .env.example)');
        return;
      }
      for (final (blobHex, expected) in vectors) {
        final key = HlsKeyDecryptor.keyFromUri(_encDataUri(blobHex));
        expect(key, isNotNull, reason: 'no key for blob $blobHex');
        expect(key!.length, 16);
        expect(_hex(key), expected, reason: 'wrong key for blob $blobHex');
      }
    });

    test('returns the raw bytes for a plain 16-byte data: key', () {
      // 16 raw bytes, base64 inline (no ENC: tag) → used verbatim.
      final uri = 'data:application/octet-stream;base64,'
          '${base64.encode(_fromHex('000102030405060708090a0b0c0d0e0f'))}';
      final key = HlsKeyDecryptor.keyFromUri(uri);
      expect(key, isNotNull);
      expect(_hex(key!), '000102030405060708090a0b0c0d0e0f');
    });

    test('ignores non-data URIs and malformed input', () {
      expect(HlsKeyDecryptor.keyFromUri('https://x/key.bin'), isNull);
      expect(HlsKeyDecryptor.keyFromUri('data:text/plain;base64,@@@@'), isNull);
      expect(HlsKeyDecryptor.keyFromUri('not a uri'), isNull);
    });
  });
}
