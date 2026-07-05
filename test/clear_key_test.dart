import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vp/services/clear_key.dart';

void main() {
  group('ClearKeyResolver', () {
    test('plain URL: no key, no format sniffed', () {
      final r = ClearKeyResolver.resolve('https://h.tld/a.mp4');
      expect(r.url, 'https://h.tld/a.mp4');
      expect(r.isEncrypted, isFalse);
      expect(r.format, isNull);
    });

    test('detects DASH and HLS formats', () {
      expect(ClearKeyResolver.resolve('https://h.tld/x/index.mpd?a=b').format,
          'dash');
      expect(ClearKeyResolver.resolve('https://h.tld/x/index.m3u8').format,
          'hls');
    });

    test('splits ### and builds ClearKey JSON (real MBC-style key)', () {
      const mpd =
          'https://mbcvod-enc.edgenextcdn.net/out/v1/abc/def/ghi/index.mpd?aws.manifestfilter=video_codec:H264';
      const key = '3JiNt9Bxu6h/Jq7rdNagKA:74bp3RHIScabj0+anXgz1g';
      final r = ClearKeyResolver.resolve('$mpd###$key');

      expect(r.url, mpd);
      expect(r.format, 'dash');
      expect(r.isEncrypted, isTrue);

      final json = jsonDecode(r.clearKeyJson!) as Map<String, dynamic>;
      expect(json['type'], 'temporary');
      final keys = json['keys'] as List;
      expect(keys, hasLength(1));
      final entry = keys.first as Map<String, dynamic>;
      expect(entry['kty'], 'oct');
      // Emitted as base64url (EME/JWK): '/' -> '_', '+' -> '-', no padding.
      expect(entry['k'], '3JiNt9Bxu6h_Jq7rdNagKA');
      expect(entry['kid'], '74bp3RHIScabj0-anXgz1g');
    });

    test('supports multiple pipe-separated keys', () {
      final r = ClearKeyResolver.resolve(
          'https://h.tld/i.mpd###3JiNt9Bxu6h/Jq7rdNagKA:74bp3RHIScabj0+anXgz1g|3JiNt9Bxu6h/Jq7rdNagKA:74bp3RHIScabj0+anXgz1g');
      final keys = (jsonDecode(r.clearKeyJson!) as Map)['keys'] as List;
      expect(keys, hasLength(2));
    });

    test('malformed key string yields no DRM (graceful)', () {
      final r = ClearKeyResolver.resolve('https://h.tld/i.mpd###notakey');
      expect(r.url, 'https://h.tld/i.mpd');
      expect(r.isEncrypted, isFalse);
    });
  });

  group('needsSniff (obfuscated live hand-offs)', () {
    bool needs(String url) =>
        ClearKeyResolver.needsSniff(ClearKeyResolver.resolve(url));

    test('opaque extensions require a content probe', () {
      // The real beIN Max hand-off: HLS disguised as .json with a token.
      expect(
          needs(
              'https://www.nazika.shop/x1/54_42.json?token=abc&expires=1&exp=2'),
          isTrue);
      expect(needs('https://h.tld/x/54_42.js'), isTrue);
      expect(needs('https://h.tld/live/channel1'), isTrue); // no extension
      expect(needs('https://h.tld/stream.php?id=9'), isTrue);
    });

    test('known containers do not need a probe', () {
      expect(needs('https://h.tld/a.mp4'), isFalse);
      expect(needs('https://h.tld/a.mkv?x=1'), isFalse);
      expect(needs('https://h.tld/a.m3u8'), isFalse); // already tagged hls
      expect(needs('https://h.tld/a.mpd?y=2'), isFalse); // already tagged dash
    });

    test('withFormat overrides the container after sniffing', () {
      final r = ClearKeyResolver.resolve('https://h.tld/x/54_42.json?token=a');
      expect(r.format, isNull);
      expect(r.withFormat('hls').format, 'hls');
      // The manifest URL and any DRM config are preserved.
      expect(r.withFormat('hls').url, 'https://h.tld/x/54_42.json?token=a');
    });
  });
}
