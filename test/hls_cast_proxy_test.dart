import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:vp/services/cast_proxy_server.dart';
import 'package:vp/services/hls_rewriter.dart';

Uint8List _bytes(List<int> b) => Uint8List.fromList(b);

/// Reference AES-128-CBC/PKCS7 encryptor (what an HLS origin does per segment).
Uint8List _encrypt(Uint8List key, Uint8List iv, List<int> plain) {
  final cipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
    ..init(
        true,
        PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
            ParametersWithIV(KeyParameter(key), iv), null));
  return cipher.process(Uint8List.fromList(plain));
}

Uint8List _sequenceIv(int sequence) {
  final iv = Uint8List(16);
  for (var i = 0; i < 8; i++) {
    iv[15 - i] = (sequence >> (8 * i)) & 0xff;
  }
  return iv;
}

void main() {
  final base = Uri.parse('https://cdn.example.com/live/chan/720.json');

  group('HlsRewriter — media playlists', () {
    test('AES-128 key line is stripped and segments carry key + explicit IV',
        () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-VERSION:3\n'
          '#EXT-X-TARGETDURATION:6\n'
          '#EXT-X-MEDIA-SEQUENCE:42\n'
          '#EXT-X-KEY:METHOD=AES-128,URI="../key.bin",IV=0x000000000000000000000000000000AB\n'
          '#EXTINF:6.0,\n'
          'seg42.php\n'
          '#EXTINF:6.0,\n'
          'seg43.php\n';
      final out = HlsRewriter.rewrite(playlist, base);

      expect(out, isNot(contains('#EXT-X-KEY')));
      expect(out, contains('#EXT-X-MEDIA-SEQUENCE:42'));
      final segLines =
          out.split('\n').where((l) => l.startsWith('seg.ts?')).toList();
      expect(segLines, hasLength(2));
      // Explicit IV applies to every segment under this key.
      for (final line in segLines) {
        expect(line, contains('&iv=000000000000000000000000000000ab'));
        final k = RegExp(r'&k=([^&]+)').firstMatch(line)!.group(1)!;
        expect(HlsRewriter.decodeUrl(k),
            'https://cdn.example.com/live/key.bin');
      }
      final u = RegExp(r'u=([^&]+)').firstMatch(segLines.first)!.group(1)!;
      expect(HlsRewriter.decodeUrl(u),
          'https://cdn.example.com/live/chan/seg42.php');
    });

    test('missing IV attr derives per-segment IV from the media sequence', () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-MEDIA-SEQUENCE:7\n'
          '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
          '#EXTINF:6.0,\n'
          'a.ts\n'
          '#EXTINF:6.0,\n'
          'b.ts\n';
      final out = HlsRewriter.rewrite(playlist, base);
      final ivs = RegExp(r'&iv=([0-9a-f]{32})')
          .allMatches(out)
          .map((m) => m.group(1))
          .toList();
      expect(ivs, [
        '00000000000000000000000000000007',
        '00000000000000000000000000000008',
      ]);
    });

    test('METHOD=NONE turns decryption back off', () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
          '#EXTINF:6.0,\n'
          'enc.ts\n'
          '#EXT-X-KEY:METHOD=NONE\n'
          '#EXTINF:6.0,\n'
          'clear.ts\n';
      final out = HlsRewriter.rewrite(playlist, base);
      final segLines =
          out.split('\n').where((l) => l.startsWith('seg.ts?')).toList();
      expect(segLines[0], contains('&k='));
      expect(segLines[1], isNot(contains('&k=')));
      expect(out, contains('#EXT-X-KEY:METHOD=NONE'));
    });

    test('bogus PROGRAM-DATE-TIME lines are stripped, EXTINF kept', () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-PROGRAM-DATE-TIME:2093-05-01T12:00:00Z\n'
          '#EXTINF:6.0,\n'
          'seg.ts\n';
      final out = HlsRewriter.rewrite(playlist, base);
      expect(out, isNot(contains('PROGRAM-DATE-TIME')));
      expect(out, contains('#EXTINF:6.0,'));
    });

    test('absolute segment URLs and query strings survive the round-trip', () {
      const playlist = '#EXTM3U\n'
          '#EXTINF:6.0,\n'
          'https://edge.example.net/s/1.jpg?tok=a+b&x=1\n';
      final out = HlsRewriter.rewrite(playlist, base);
      final u = RegExp(r'u=([^&\s]+)').firstMatch(out)!.group(1)!;
      expect(HlsRewriter.decodeUrl(u),
          'https://edge.example.net/s/1.jpg?tok=a+b&x=1');
    });

    test('encrypted EXT-X-MAP carries a key + IV so it is not served encrypted',
        () {
      const explicit = '#EXTM3U\n'
          '#EXT-X-MEDIA-SEQUENCE:3\n'
          '#EXT-X-KEY:METHOD=AES-128,URI="k.bin",IV=0x000000000000000000000000000000FF\n'
          '#EXT-X-MAP:URI="init.mp4"\n'
          '#EXTINF:6.0,\n'
          'a.ts\n';
      final e = HlsRewriter.rewrite(explicit, base);
      final mapLine = e.split('\n').firstWhere((l) => l.contains('EXT-X-MAP'));
      expect(mapLine, contains('seg.ts?'));
      expect(mapLine, contains('&k='));
      expect(mapLine, contains('&iv=000000000000000000000000000000ff'));

      // No explicit IV → falls back to the media-sequence IV (never a bare ref).
      const implicit = '#EXTM3U\n'
          '#EXT-X-MEDIA-SEQUENCE:3\n'
          '#EXT-X-KEY:METHOD=AES-128,URI="k.bin"\n'
          '#EXT-X-MAP:URI="init.mp4"\n';
      final i = HlsRewriter.rewrite(implicit, base);
      final mapLine2 = i.split('\n').firstWhere((l) => l.contains('EXT-X-MAP'));
      expect(mapLine2, contains('&k='));
      expect(mapLine2, contains('&iv=00000000000000000000000000000003'));
    });

    test('malformed AES-128 key with no URI resets key state (no stale key)',
        () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-KEY:METHOD=AES-128,URI="k.bin"\n'
          '#EXTINF:6.0,\n'
          'enc.ts\n'
          '#EXT-X-KEY:METHOD=AES-128\n' // malformed: no URI
          '#EXTINF:6.0,\n'
          'after.ts\n';
      final out = HlsRewriter.rewrite(playlist, base);
      final segs =
          out.split('\n').where((l) => l.startsWith('seg.ts?')).toList();
      expect(segs[0], contains('&k='));
      // The segment after the malformed key must NOT reuse the previous key.
      expect(segs[1], isNot(contains('&k=')));
    });
  });

  group('HlsRewriter — master playlists', () {
    test('variant, EXT-X-MEDIA and I-frame URIs proxy back to playlist.m3u8',
        () {
      const playlist = '#EXTM3U\n'
          '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="ar",URI="audio/ar.m3u8"\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=800000,AUDIO="aud"\n'
          'v720.m3u8\n'
          '#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=100000,URI="iframe.m3u8"\n';
      final out = HlsRewriter.rewrite(playlist, base);
      expect(out, isNot(contains('seg.ts?')));
      expect(RegExp(r'playlist\.m3u8\?u=').allMatches(out), hasLength(3));
      final variant = out
          .split('\n')
          .firstWhere((l) => l.startsWith('playlist.m3u8?'));
      final u = RegExp(r'u=(.+)').firstMatch(variant)!.group(1)!;
      expect(HlsRewriter.decodeUrl(u),
          'https://cdn.example.com/live/chan/v720.m3u8');
    });
  });

  group('AES-128-CBC', () {
    test('decryptAes128Cbc inverts a reference encryption', () {
      final key = _bytes(List.generate(16, (i) => i * 7 & 0xff));
      final iv = _sequenceIv(42);
      final plain = List<int>.generate(1000, (i) => (i * 31) & 0xff);
      final enc = _encrypt(key, iv, plain);
      expect(enc.length % 16, 0);
      expect(HlsCastProxy.decryptAes128Cbc(key, iv, enc), plain);
    });

    test('rejects ciphertext that is not block-aligned', () {
      expect(
          () => HlsCastProxy.decryptAes128Cbc(
              Uint8List(16), Uint8List(16), Uint8List(17)),
          throwsStateError);
    });
  });

  group('HlsCastProxy end-to-end (local upstream)', () {
    late HttpServer upstream;
    late Uri upstreamBase;
    final key = _bytes(List.generate(16, (i) => 255 - i));
    final segPlain = List<int>.generate(3760, (i) => (i ^ 0x47) & 0xff);
    const ua = 'Mozilla/5.0 test-desktop-chrome';
    final upstreamHits = <String>[];

    setUpAll(() async {
      upstream = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      upstreamBase = Uri.parse('http://127.0.0.1:${upstream.port}/');
      upstream.listen((req) async {
        upstreamHits.add(req.uri.path);
        final res = req.response;
        // The whole point of the proxy: origin is UA-gated.
        if (req.headers.value('user-agent') != ua) {
          res.statusCode = 403;
          await res.close();
          return;
        }
        switch (req.uri.path) {
          case '/live/master.json':
            res.write('#EXTM3U\n'
                '#EXT-X-STREAM-INF:BANDWIDTH=800000\n'
                'chan/media.json\n');
            break;
          case '/live/chan/media.json':
            res.write('#EXTM3U\n'
                '#EXT-X-TARGETDURATION:6\n'
                '#EXT-X-MEDIA-SEQUENCE:7\n'
                '#EXT-X-KEY:METHOD=AES-128,URI="../key.bin"\n'
                '#EXT-X-PROGRAM-DATE-TIME:2093-05-01T12:00:00Z\n'
                '#EXTINF:6.0,\n'
                'seg7.php\n');
            break;
          case '/live/key.bin':
            res.add(key);
            break;
          case '/live/chan/seg7.php':
            res.add(_encrypt(key, _sequenceIv(7), segPlain));
            break;
          default:
            res.statusCode = 404;
        }
        await res.close();
      });
    });

    tearDownAll(() async {
      await upstream.close(force: true);
    });

    test('playlist chain rewrites, key stays phone-side, segment comes back '
        'clear, and /beacon records receiver telemetry', () async {
      final proxy = HlsCastProxy(
        upstreamPlaylistUrl:
            upstreamBase.resolve('/live/master.json').toString(),
        upstreamHeaders: const {'User-Agent': ua},
      );
      final entry = await proxy.start();
      expect(entry, isNotNull, reason: 'host has no LAN IPv4');
      final client = HttpClient();

      Future<Uint8List> fetch(Uri url) async {
        final resp = await (await client.getUrl(url)).close();
        expect(resp.statusCode, 200, reason: 'GET $url');
        final b = <int>[];
        await for (final c in resp) {
          b.addAll(c);
        }
        return Uint8List.fromList(b);
      }

      // Master → rewritten variant ref.
      final master = String.fromCharCodes(await fetch(entry!));
      final variantRef = master
          .split('\n')
          .firstWhere((l) => l.startsWith('playlist.m3u8?'));

      // Variant (media) playlist: key line gone, PDT gone, seg proxied.
      final media =
          String.fromCharCodes(await fetch(entry.resolve(variantRef)));
      expect(media, isNot(contains('#EXT-X-KEY')));
      expect(media, isNot(contains('PROGRAM-DATE-TIME')));
      final segRef =
          media.split('\n').firstWhere((l) => l.startsWith('seg.ts?'));
      expect(segRef, contains('&iv=00000000000000000000000000000007'));

      // Segment arrives decrypted; the AES key was never served to the client.
      final seg = await fetch(entry.resolve(segRef));
      expect(seg, segPlain);
      expect(upstreamHits, contains('/live/key.bin'));

      // Receiver telemetry lands in receiverLog via POST /beacon.
      final post = await client.postUrl(entry.resolve('/beacon'));
      post.write('canPlay hvc1(fMP4): probably\nstate=PLAYING');
      final postRes = await post.close();
      expect(postRes.statusCode, 204);
      expect(proxy.receiverLog,
          containsAll(['canPlay hvc1(fMP4): probably', 'state=PLAYING']));

      // Live semantics: every playlist poll re-fetches upstream.
      final mediaHits = upstreamHits
          .where((p) => p == '/live/chan/media.json')
          .length;
      await fetch(entry.resolve(variantRef));
      expect(
          upstreamHits.where((p) => p == '/live/chan/media.json').length,
          mediaHits + 1);

      client.close(force: true);
      await proxy.stop();
    });
  });

  group('HlsCastProxy hardening', () {
    late HttpServer upstream;
    late Uri upstreamBase;

    setUpAll(() async {
      upstream = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      upstreamBase = Uri.parse('http://127.0.0.1:${upstream.port}/');
      upstream.listen((req) async {
        // Every path 404s — used to prove the proxy rejects an upstream error
        // instead of relaying its error body as media.
        req.response.statusCode = 404;
        await req.response.close();
      });
    });

    tearDownAll(() async {
      await upstream.close(force: true);
    });

    String enc(String url) =>
        base64Url.encode(utf8.encode(url)).replaceAll('=', '');

    Future<int> status(Uri url, {String method = 'GET', List<int>? body}) async {
      final client = HttpClient();
      try {
        final req = await client.openUrl(method, url);
        if (body != null) req.add(body);
        final resp = await req.close();
        await resp.drain<void>();
        return resp.statusCode;
      } finally {
        client.close(force: true);
      }
    }

    test('SSRF: a segment whose host was never referenced is 403', () async {
      final proxy = HlsCastProxy(
        upstreamPlaylistUrl: upstreamBase.resolve('/live/x.json').toString(),
      );
      final entry = (await proxy.start())!;
      // 169.254.169.254 (cloud metadata) was never in any served playlist.
      final evil = enc('http://169.254.169.254/latest/meta-data/');
      expect(await status(entry.resolve('/seg.ts?u=$evil')),
          HttpStatus.forbidden);
      // A key pointing off-allowlist is likewise refused.
      final okHost = enc(upstreamBase.resolve('/live/seg1.ts').toString());
      final evilKey = enc('http://10.0.0.1/key');
      expect(
          await status(entry.resolve('/seg.ts?u=$okHost&k=$evilKey'
              '&iv=00000000000000000000000000000000')),
          HttpStatus.forbidden);
      await proxy.stop();
    });

    test('upstream non-2xx is surfaced as 502, not relayed as media', () async {
      final proxy = HlsCastProxy(
        upstreamPlaylistUrl: upstreamBase.resolve('/live/x.json').toString(),
      );
      final entry = (await proxy.start())!;
      // Seeded upstream host is allow-listed, so this passes the SSRF gate and
      // reaches _fetch, which sees the upstream 404 and must throw → 502.
      final segUrl = enc(upstreamBase.resolve('/live/gone.ts').toString());
      expect(await status(entry.resolve('/seg.ts?u=$segUrl')),
          HttpStatus.badGateway);
      await proxy.stop();
    });

    test('/beacon rejects an oversized body', () async {
      final proxy = HlsCastProxy(
        upstreamPlaylistUrl: upstreamBase.resolve('/live/x.json').toString(),
      );
      final entry = (await proxy.start())!;
      final huge = List<int>.filled(80 * 1024, 0x41); // 80 KiB > 64 KiB cap
      expect(await status(entry.resolve('/beacon'), method: 'POST', body: huge),
          HttpStatus.requestEntityTooLarge);
      // A small beacon still works.
      expect(
          await status(entry.resolve('/beacon'),
              method: 'POST', body: utf8.encode('hello')),
          204);
      await proxy.stop();
    });
  });
}
