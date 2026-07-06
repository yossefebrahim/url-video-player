import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vp/models/video_item.dart';
import 'package:vp/services/link_parser.dart';

/// Sender-side encoder that mirrors what a hand-off app (e.g. Ostora) does to
/// build a `urlplayer://play?url=<X>` link. It is the exact inverse of the
/// decode implemented in [LinkParser] / the original `Scheme` activity:
///   URLEncode -> XOR(key) -> URL-safe Base64.
String encodeObfuscated(String rawUrl) {
  const key = 'jMkn9kbN4Xr8V3NKXdsRA7QwY4Ars9mv4Xr8V3NKXYFhbYgw';
  final urlEncoded = Uri.encodeQueryComponent(rawUrl);
  final buf = StringBuffer();
  for (var i = 0; i < urlEncoded.length; i++) {
    buf.writeCharCode(
        urlEncoded.codeUnitAt(i) ^ key.codeUnitAt(i % key.length));
  }
  // XOR output is guaranteed to stay in 0..127, so code units == bytes.
  return base64Url.encode(buf.toString().codeUnits);
}

void main() {
  group('obfuscated deep links (Ostora-compatible)', () {
    test('urlplayer://play round-trips a direct video URL', () {
      const raw = 'http://example.com/live/stream/index.m3u8?token=abc123';
      final enc = encodeObfuscated(raw);
      final link = LinkParser.parseUri('urlplayer://play?url=$enc');

      expect(link, isNotNull);
      expect(link!.item.url, raw);
      expect(link.item.mode, PlayerMode.native);
      expect(link.autoPlay, isTrue);
      expect(link.item.source, VideoSource.deepLink);
    });

    test('urlvplayer scheme is treated the same as urlplayer', () {
      const raw = 'https://cdn.test/movie.mp4';
      final enc = encodeObfuscated(raw);
      final link = LinkParser.parseUri('urlvplayer://play?url=$enc');
      expect(link!.item.url, raw);
      expect(link.item.mode, PlayerMode.native);
    });

    test('host "web" resolves to the web player', () {
      const raw = 'https://site.tld/embed/xyz';
      final enc = encodeObfuscated(raw);
      final link = LinkParser.parseUri('urlplayer://web?url=$enc');
      expect(link!.item.url, raw);
      expect(link.item.mode, PlayerMode.web);
    });

    test('agent parameter is decoded into userAgent', () {
      const raw = 'https://cdn.test/movie.mp4';
      final enc = encodeObfuscated(raw);
      final ua = Uri.encodeQueryComponent('MyPlayer/1.0 (Android)');
      final link = LinkParser.parseUri('urlplayer://play?url=$enc&agent=$ua');
      expect(link!.item.userAgent, 'MyPlayer/1.0 (Android)');
    });

    test('URLs containing + and / survive the pipeline', () {
      const raw = 'https://h.tld/a+b/c?d=e&f=g/h';
      final enc = encodeObfuscated(raw);
      final link = LinkParser.parseUri('urlplayer://play?url=$enc');
      expect(link!.item.url, raw);
    });
  });

  group('plain / direct links', () {
    test('non play/web host uses a plainly URL-decoded url param', () {
      const raw = 'https://plain.tld/video.mp4';
      final link = LinkParser.parseUri(
          'urlplayer://open?url=${Uri.encodeQueryComponent(raw)}');
      expect(link!.item.url, raw);
      expect(link.item.mode, PlayerMode.web);
    });

    test('direct https video URL opened via VIEW auto-plays natively', () {
      const raw = 'https://host.tld/path/clip.mp4';
      final link = LinkParser.parseUri(raw);
      expect(link!.item.url, raw);
      expect(link.item.mode, PlayerMode.native);
      expect(link.autoPlay, isTrue);
      expect(link.item.source, VideoSource.openWith);
    });

    test('unsupported scheme returns null', () {
      expect(LinkParser.parseUri('mailto:someone@test.tld'), isNull);
    });
  });

  group('shared text (ACTION_SEND)', () {
    test('extracts the first URL from shared text and pre-fills only', () {
      final link = LinkParser.parsePayload({
        'type': 'send',
        'text': 'Watch this: https://share.tld/v/9.m3u8 great stream',
      });
      expect(link!.item.url, 'https://share.tld/v/9.m3u8');
      expect(link.autoPlay, isFalse);
      expect(link.item.source, VideoSource.shared);
    });

    test('returns null when no URL is present', () {
      final link = LinkParser.parsePayload({'type': 'send', 'text': 'hello'});
      expect(link, isNull);
    });
  });

  group('explicit-component hand-off (extra payload, Ostora-style)', () {
    test('plain url extra auto-plays natively with agent', () {
      final link = LinkParser.parsePayload({
        'type': 'extra',
        'url': 'https://host.tld/live/x.m3u8',
        'agent': 'ExoPlayer/2',
      });
      expect(link!.item.url, 'https://host.tld/live/x.m3u8');
      expect(link.item.userAgent, 'ExoPlayer/2');
      expect(link.item.mode, PlayerMode.native);
      expect(link.autoPlay, isTrue);
    });

    test('strips the urlvplayer:// marker prefix', () {
      final link = LinkParser.parsePayload({
        'type': 'extra',
        'url': 'urlvplayer://https://host.tld/redirect.m3u8',
      });
      expect(link!.item.url, 'https://host.tld/redirect.m3u8');
    });

    test('"Web Player" agent placeholder is treated as no user agent', () {
      final link = LinkParser.parsePayload({
        'type': 'extra',
        'url': 'https://host.tld/a.mp4',
        'agent': 'Web Player',
      });
      expect(link!.item.userAgent, isNull);
    });
  });

  group('garbage-prefixed URLs (Ostora 407<F> regression)', () {
    test('extra: strips a "407<F>" prefix before the real https URL', () {
      final link = LinkParser.parsePayload({
        'type': 'extra',
        'url': '407<F>https://mbcvod-enc.edgenextcdn.net/out/v1/x/index.mpd'
            '?aws.manifestfilter=video_codec:H264',
      });
      expect(link!.item.url,
          'https://mbcvod-enc.edgenextcdn.net/out/v1/x/index.mpd'
          '?aws.manifestfilter=video_codec:H264');
    });

    test('obfuscated urlplayer://play decode + sanitize yields a clean URL', () {
      const garbage = '407<F>https://www2.nazika.shop/x1/56_4.json?token=abc';
      final enc = encodeObfuscated(garbage);
      final link = LinkParser.parseUri('urlplayer://play?url=$enc');
      expect(link!.item.url,
          'https://www2.nazika.shop/x1/56_4.json?token=abc');
      expect(link.item.mode, PlayerMode.native);
    });

    test('preserves the ###k:kid ClearKey suffix when stripping a prefix', () {
      final link = LinkParser.parsePayload({
        'type': 'extra',
        'url': 'GARBAGE-https://host.tld/index.mpd###key:kid',
      });
      expect(link!.item.url, 'https://host.tld/index.mpd###key:kid');
    });

    test('leaves a clean URL untouched (no-op), incl. later http in a query',
        () {
      final link = LinkParser.parsePayload({
        'type': 'extra',
        'url': 'https://host.tld/p?next=http://other.tld/a.mp4',
      });
      expect(link!.item.url, 'https://host.tld/p?next=http://other.tld/a.mp4');
    });
  });

  group('titleFromUrl', () {
    test('derives a readable title from the file name', () {
      expect(LinkParser.titleFromUrl('http://h.tld/a/My_Great-Movie.mp4'),
          'My Great Movie');
    });

    test('falls back to host when there is no path', () {
      expect(LinkParser.titleFromUrl('https://only-host.tld'), 'only-host.tld');
    });
  });
}
