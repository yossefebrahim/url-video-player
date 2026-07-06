import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vp/services/cenc_decryptor.dart';

/// Real MBC ClearKey content key (`3JiNt9Bxu6h/Jq7rdNagKA` → hex).
final _key = Uint8List.fromList([
  0xdc, 0x98, 0x8d, 0xb7, 0xd0, 0x71, 0xbb, 0xa8,
  0x7f, 0x26, 0xae, 0xeb, 0x74, 0xd6, 0xa0, 0x28,
]);

bool _hasBox(Uint8List d, String type) {
  final t = Uint8List.fromList(type.codeUnits);
  for (var i = 0; i + 4 <= d.length; i++) {
    if (d[i] == t[0] && d[i + 1] == t[1] && d[i + 2] == t[2] && d[i + 3] == t[3]) {
      return true;
    }
  }
  return false;
}

void main() {
  // These fixtures are a real CENC (cenc/AES-CTR, IV=8, subsample) H.264 init +
  // first media segment. The known-answer hashes were produced by the validated
  // harness whose output is byte-identical to ffmpeg's `-decryption_key`.
  final init = File('test/fixtures/cenc_video_init.mp4').readAsBytesSync();
  final seg = File('test/fixtures/cenc_video_seg1.mp4').readAsBytesSync();

  group('CencDecryptor', () {
    test('rewriteInit clears the sample entry and reads IV size', () {
      final dec = CencDecryptor(_key);
      final out = dec.rewriteInit(Uint8List.fromList(init));
      expect(dec.ivSize, 8);
      expect(_hasBox(out, 'avc1'), isTrue, reason: 'encv → avc1');
      expect(_hasBox(out, 'encv'), isFalse, reason: 'no encrypted sample entry');
      expect(_hasBox(out, 'sinf'), isFalse, reason: 'protection scheme neutralised');
      // Known-answer: exact bytes of the cleared init.
      expect(sha256.convert(out).toString(),
          '2d27a823b94b7050263a361fcffbde53e960921eb9eff13d00f074b085cb2746');
    });

    test('decryptSegment produces byte-exact clear fMP4 (matches ffmpeg)', () {
      final dec = CencDecryptor(_key)..rewriteInit(Uint8List.fromList(init));
      final out = dec.decryptSegment(Uint8List.fromList(seg));
      expect(out.length, seg.length, reason: 'size-preserving');
      expect(_hasBox(out, 'senc'), isFalse, reason: 'senc → free');
      expect(sha256.convert(out).toString(),
          '3b9592661c55c94de7a4d901b34565e9b3291e1cc07b64727a551e6d18da5f1b');
    });

    test('is deterministic', () {
      final a = (CencDecryptor(_key)..rewriteInit(Uint8List.fromList(init)))
          .decryptSegment(Uint8List.fromList(seg));
      final b = (CencDecryptor(_key)..rewriteInit(Uint8List.fromList(init)))
          .decryptSegment(Uint8List.fromList(seg));
      expect(base64.encode(a), base64.encode(b));
    });
  });
}
