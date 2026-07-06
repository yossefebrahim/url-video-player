import 'dart:convert';
import 'dart:typed_data';

/// Unwraps the obfuscated HLS content key used by the t4w / nazika live-TV
/// ecosystem (beIN etc.), where `#EXT-X-KEY` carries an inline `data:` URI whose
/// payload is `ENC:<base64>` rather than a raw 16-byte AES key.
///
/// This is a faithful, byte-for-byte port of the original `info.t4w.vp`
/// "Url Video Player" app's native `libnext.so`
/// (`info.t4w.vp.view.HlsKeyDecryptor.decryptNative`), verified against the real
/// library on-device across 300+ random vectors (see
/// `test/hls_key_decryptor_test.dart`). ExoPlayer cannot fetch a `data:` key
/// (`unknown protocol: data`), so [LiveHlsProxy] uses this to recover the real
/// key and localise it for the player.
///
/// Pipeline (mirrors the original Java `e8$mp_s$` + native `decryptNative`):
///   `data:…;base64,B64`  →  base64-decode → bytes `ENC:<inner-b64>`
///   → drop the 4-byte `ENC:` tag, base64-decode the rest → the 32-byte *blob*
///   → [_decrypt] (custom FNV-1a keystream cipher) → the 16-byte AES-128 key.
class HlsKeyDecryptor {
  HlsKeyDecryptor._();

  static const int _fnvBasis = 0x811c9dc5;
  static const int _fnvPrime = 0x01000193;
  static const int _mask32 = 0xffffffff;

  /// The 32-byte hardcoded key string, read verbatim from `libnext.so` .rodata
  /// (@0x11f0): the ASCII text "0b1d565898807f406d650ea731f0f08c".
  static final Uint8List _hardKey =
      Uint8List.fromList(ascii.encode('0b1d565898807f406d650ea731f0f08c'));

  /// Resolves an `#EXT-X-KEY` `URI` value to a raw AES-128 key, or null when it
  /// isn't an inline `data:` key we can turn into 16 bytes.
  ///
  /// Handles both the obfuscated `ENC:` form (unwrapped via [_decrypt]) and a
  /// plain `data:` key whose decoded bytes are already the 16-byte key.
  static Uint8List? keyFromUri(String uri) {
    if (!uri.startsWith('data:')) return null;
    final comma = uri.indexOf(',');
    if (comma < 0) return null;
    final meta = uri.substring(5, comma); // between "data:" and ","
    var payload = uri.substring(comma + 1);
    try {
      final Uint8List decoded;
      if (meta.contains('base64')) {
        decoded = base64.decode(base64.normalize(payload.trim()));
      } else {
        decoded = Uint8List.fromList(utf8.encode(Uri.decodeComponent(payload)));
      }
      if (_hasEncTag(decoded)) {
        // ENC:<inner-base64> — strip the 4-byte tag, decode, run the cipher.
        final inner =
            ascii.decode(decoded.sublist(4), allowInvalid: true).trim();
        final blob = base64.decode(base64.normalize(inner));
        return _decrypt(blob);
      }
      // Plain inline key: usable directly only if it's exactly 16 bytes.
      return decoded.length == 16 ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static bool _hasEncTag(Uint8List b) =>
      b.length >= 4 && b[0] == 0x45 && b[1] == 0x4e && b[2] == 0x43 && b[3] == 0x3a; // "ENC:"

  /// The custom FNV-1a keystream cipher. Input [blob] must be > 16 bytes; the
  /// output length is `blob.length - 16` (a 32-byte blob → the 16-byte key).
  ///
  /// The first 16 blob bytes are an absorbed salt; the last `len-16` are the
  /// ciphertext XORed with a keystream derived from [_hardKey] and that salt.
  static Uint8List? _decrypt(Uint8List blob) {
    final n = blob.length;
    if (n <= 16) return null;
    final outLen = n - 16;

    // Stage 1 — build a 32-byte keystream buffer from the hardcoded key.
    final buf = Uint8List(32);
    var state = _fnvBasis;
    for (var i = 0; i < 32; i++) {
      state = (state ^ _hardKey[i]) & _mask32;
      final tmp = buf[i];
      state = (state * _fnvPrime) & _mask32;
      buf[i] = (tmp ^ state) & 0xff;
      final w = (i + 1) & 31;
      buf[w] = (buf[w] ^ ((state >> 8) & 0xff)) & 0xff;
    }

    // Stage 2 — absorb the 16-byte salt (blob[0..16]) into the buffer.
    for (var i = 0; i < 16; i++) {
      state = (state ^ blob[i]) & _mask32;
      state = (state * _fnvPrime) & _mask32;
      final bi = buf[i];
      final bi3 = buf[i + 3];
      buf[i] = (bi ^ state) & 0xff;
      buf[i + 3] = (bi3 ^ ((state >> 16) & 0xff)) & 0xff;
    }

    // Stage 3 — an intermediate keystream from the buffer + rolling counters.
    final ks = Uint8List(outLen);
    var b = 0;
    var w14 = buf[0];
    for (var i = 0; i < outLen; i++) {
      final r = i % 7;
      var val = (b ^ w14) & _mask32;
      b = (b + 0x6d) & _mask32;
      val = (val ^ _rol8(buf[i & 31], r + 1)) & _mask32;
      ks[i] = val & 0xff;
      w14 = (buf[(i + 7) & 31] ^ (val & 0xff)) & 0xff;
    }

    // Stage 4 — XOR the ciphertext (blob[16..]) with the keystream, ciphertext
    // byte right-rotated by (i%7)+1.
    final out = Uint8List(outLen);
    for (var i = 0; i < outLen; i++) {
      out[i] = (ks[i] ^ _ror8(blob[16 + i], (i % 7) + 1)) & 0xff;
    }
    return out;
  }

  static int _rol8(int b, int k) {
    k &= 7;
    if (k == 0) return b & 0xff;
    return ((b << k) | (b >> (8 - k))) & 0xff;
  }

  static int _ror8(int b, int k) {
    k &= 7;
    if (k == 0) return b & 0xff;
    return ((b >> k) | (b << (8 - k))) & 0xff;
  }
}
