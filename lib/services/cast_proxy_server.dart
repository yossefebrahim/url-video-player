import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'cenc_decryptor.dart';
import 'hls_rewriter.dart';

/// Debug-only logger (keeps this file free of a Flutter dependency so it stays
/// unit-testable as pure Dart).
void _log(String message) {
  assert(() {
    // ignore: avoid_print
    print('[CastProxy] $message');
    return true;
  }());
}

/// Common plumbing for the per-session LAN proxies that let a Chromecast play
/// streams its receiver can't fetch or decode on its own: bind on the phone's
/// LAN IPv4, CORS for the receiver's web runtime, upstream fetches carrying
/// the item's headers (User-Agent — Cast senders can never apply it), and the
/// `POST /beacon` endpoint the custom receiver reports its telemetry to
/// (HEVC capability probe, player errors) so TV-side state is readable from
/// the phone's log during bring-up.
///
/// Cast is a hand-off, so a proxy must stay alive for the whole session and
/// the phone must stay on the same Wi-Fi as the TV. [CastService] holds a
/// wakelock while one is running so Doze can't strand the receiver.
abstract class CastProxy {
  CastProxy({this.upstreamHeaders = const {}});

  final Map<String, String> upstreamHeaders;

  HttpServer? _server;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  /// Receiver-side telemetry lines POSTed to `/beacon` (newest last, capped).
  final List<String> receiverLog = [];

  /// Path of the entry-point resource the Cast receiver should load.
  String get entryPath;

  /// Handles one non-beacon request; the entry URL is what [start] returned.
  Future<void> handleRequest(HttpRequest req);

  /// Binds the server and returns the URL the Chromecast should load,
  /// e.g. `http://192.168.1.5:49xxx/manifest.mpd`. Null if no LAN IP is found.
  Future<Uri?> start() async {
    final ip = await _lanIpv4();
    if (ip == null) return null;
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0, shared: true);
    _server!.listen(_dispatch, onError: (e) => _log('server error: $e'));
    return Uri.parse('http://$ip:${_server!.port}$entryPath');
  }

  Future<void> stop() async {
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
    _client.close(force: true);
  }

  Future<void> _dispatch(HttpRequest req) async {
    final res = req.response;
    _cors(res);
    try {
      if (req.method == 'OPTIONS') {
        res.statusCode = 200;
        await res.close();
        return;
      }
      if (req.uri.path == '/beacon') {
        await _handleBeacon(req);
        return;
      }
      await handleRequest(req);
    } catch (e) {
      _log('handler failed for ${req.uri}: $e');
      try {
        res.statusCode = 502;
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> _handleBeacon(HttpRequest req) async {
    final body = await utf8.decodeStream(req.cast<List<int>>());
    for (final line in const LineSplitter().convert(body)) {
      if (line.trim().isEmpty) continue;
      receiverLog.add(line);
      _log('[receiver] $line');
    }
    while (receiverLog.length > 200) {
      receiverLog.removeAt(0);
    }
    req.response.statusCode = 204;
    await req.response.close();
  }

  // ── networking ─────────────────────────────────────────────────────────────

  Future<Uint8List> fetchBytes(String url) async =>
      (await _fetch(url)).$1;

  /// Fetches [url] and returns (body, effectiveUrl) — live playlists commonly
  /// redirect to a CDN edge, and relative segment URIs must resolve against
  /// the URL that actually served the playlist, not the one we asked for.
  Future<(Uint8List, Uri)> _fetch(String url) async {
    final uri = Uri.parse(url);
    final req = await _client.getUrl(uri);
    upstreamHeaders.forEach(req.headers.set);
    final resp = await req.close();
    var effective = uri;
    for (final r in resp.redirects) {
      effective = effective.resolveUri(r.location);
    }
    final chunks = <int>[];
    await for (final c in resp) {
      chunks.addAll(c);
    }
    return (Uint8List.fromList(chunks), effective);
  }

  void _cors(HttpResponse res) {
    res.headers.set('Access-Control-Allow-Origin', '*');
    res.headers.set('Access-Control-Allow-Headers', '*');
    res.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  }

  /// First private (RFC 1918) IPv4 of a real interface — the phone's LAN address.
  static Future<String?> _lanIpv4() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final ni in interfaces) {
        for (final addr in ni.addresses) {
          final ip = addr.address;
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              _is172Private(ip)) {
            return ip;
          }
        }
      }
      // Fall back to any non-loopback IPv4.
      for (final ni in interfaces) {
        for (final addr in ni.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (e) {
      _log('_lanIpv4 failed: $e');
    }
    return null;
  }

  static bool _is172Private(String ip) {
    if (!ip.startsWith('172.')) return false;
    final second = int.tryParse(ip.split('.')[1]) ?? 0;
    return second >= 16 && second <= 31;
  }
}

/// A per-session local HTTP server that lets a Chromecast play a **ClearKey
/// CENC DASH** stream its default receiver can't decrypt.
///
/// The Chromecast fetches a rewritten, DRM-free manifest from the phone; the
/// server proxies each init/media segment from the real origin, decrypts it
/// with [CencDecryptor], and returns clear fMP4.
class CastProxyServer extends CastProxy {
  final String upstreamMpdUrl;
  final CencDecryptor decryptor;

  CastProxyServer({
    required this.upstreamMpdUrl,
    required this.decryptor,
    super.upstreamHeaders,
  });

  final List<_Rep> _reps = [];
  String? _rewrittenManifest;
  Future<void>? _parsing;

  @override
  String get entryPath => '/manifest.mpd';

  @override
  Future<void> handleRequest(HttpRequest req) async {
    final res = req.response;
    final path = req.uri.path;
    if (path == '/manifest.mpd') {
      await _serveManifest(res);
    } else if (path.startsWith('/init/')) {
      final idx = int.parse(path.substring('/init/'.length));
      await _serveInit(res, idx);
    } else if (path.startsWith('/seg/')) {
      final parts = path.substring('/seg/'.length).split('/');
      await _serveSegment(res, int.parse(parts[0]), parts[1]);
    } else {
      res.statusCode = 404;
      await res.close();
    }
  }

  /// Fetches + rewrites the manifest once, populating [_reps]. Memoised on the
  /// in-flight future so concurrent early segment requests can't double-fetch
  /// (a second `_reps.clear()` mid-parse would yank entries from under the
  /// request that's already indexing into them).
  Future<void> _ensureParsed() => _parsing ??= () async {
        final (bytes, effective) = await _fetch(upstreamMpdUrl);
        _rewrittenManifest =
            _rewriteManifest(String.fromCharCodes(bytes), effective);
      }();

  Future<void> _serveManifest(HttpResponse res) async {
    await _ensureParsed();
    res.headers.contentType = ContentType('application', 'dash+xml');
    res.add(Uint8List.fromList(_rewrittenManifest!.codeUnits));
    await res.close();
  }

  Future<void> _serveInit(HttpResponse res, int idx) async {
    await _ensureParsed();
    final bytes = await fetchBytes(_reps[idx].initUrl);
    final clear = decryptor.rewriteInit(bytes);
    res.headers.contentType = ContentType('video', 'mp4');
    res.add(clear);
    await res.close();
  }

  Future<void> _serveSegment(HttpResponse res, int idx, String number) async {
    await _ensureParsed();
    final url = _reps[idx].mediaTemplate.replaceAll(r'$Number$', number);
    final bytes = await fetchBytes(url);
    final clear = decryptor.decryptSegment(bytes);
    res.headers.contentType = ContentType('video', 'mp4');
    res.add(clear);
    await res.close();
  }

  // ── manifest rewriting ─────────────────────────────────────────────────────

  /// Strips ContentProtection and points every SegmentTemplate at this proxy.
  String _rewriteManifest(String mpd, Uri base) {
    _reps.clear();
    var out = mpd
        .replaceAll(RegExp(r'<ContentProtection[^>]*/>'), '')
        .replaceAll(
            RegExp(r'<ContentProtection[\s\S]*?</ContentProtection>'), '');

    out = out.replaceAllMapped(RegExp(r'<SegmentTemplate\b[^>]*>'), (m) {
      var tag = m.group(0)!;
      final initM = RegExp(r'initialization="([^"]*)"').firstMatch(tag);
      final mediaM = RegExp(r'media="([^"]*)"').firstMatch(tag);
      if (initM == null || mediaM == null) return tag;
      final idx = _reps.length;
      _reps.add(_Rep(
        initUrl: _resolve(base, initM.group(1)!),
        mediaTemplate: _resolve(base, mediaM.group(1)!),
      ));
      tag = tag.replaceFirst(initM.group(0)!, 'initialization="init/$idx"');
      tag = tag.replaceFirst(mediaM.group(0)!, 'media="seg/$idx/\$Number\$"');
      return tag;
    });
    return out;
  }

  /// Resolves a relative URL against [base] without mangling `$Number$`.
  String _resolve(Uri base, String ref) {
    const token = '__NUMBER__';
    final resolved = base.resolve(ref.replaceAll(r'$Number$', token)).toString();
    return resolved.replaceAll(token, r'$Number$');
  }
}

class _Rep {
  final String initUrl;
  final String mediaTemplate;
  _Rep({required this.initUrl, required this.mediaTemplate});
}

/// A per-session local HTTP server that lets the custom receiver play the
/// **UA-gated, AES-128-encrypted live HLS** channels (obfuscated `…/NNN.json`
/// playlists with `.php`/`.jpg` TS segments) the default receiver never could.
///
/// The receiver polls `playlist.m3u8` from the phone; each poll re-fetches the
/// rolling upstream playlist (live: MEDIA-SEQUENCE advances) with the origin
/// User-Agent and rewrites it via [HlsRewriter]. Segments are fetched with the
/// same headers, AES-128-CBC-decrypted phone-side (key URI + IV travel in the
/// rewritten segment query), and served as clear MPEG-TS. Whether the TV can
/// then *decode* the HEVC inside is the receiver's job — its verdict comes
/// back through `/beacon`.
class HlsCastProxy extends CastProxy {
  final String upstreamPlaylistUrl;

  HlsCastProxy({required this.upstreamPlaylistUrl, super.upstreamHeaders});

  /// AES keys by key-URL — fetched once, reused across segments/rotations.
  final Map<String, Uint8List> _keys = {};

  @override
  String get entryPath => '/playlist.m3u8';

  @override
  Future<void> handleRequest(HttpRequest req) async {
    final res = req.response;
    final path = req.uri.path;
    if (path == '/playlist.m3u8') {
      await _servePlaylist(res, req.uri.queryParameters['u']);
    } else if (path == '/seg.ts') {
      await _serveSegment(res, req.uri.queryParameters);
    } else if (path == '/key') {
      await _serveKey(res, req.uri.queryParameters['u']);
    } else {
      res.statusCode = 404;
      await res.close();
    }
  }

  /// Live playlists are never cached: every receiver poll re-fetches upstream
  /// so the rolling window (MEDIA-SEQUENCE) stays current.
  Future<void> _servePlaylist(HttpResponse res, String? u) async {
    final upstream =
        u == null ? upstreamPlaylistUrl : HlsRewriter.decodeUrl(u);
    final (bytes, effective) = await _fetch(upstream);
    final rewritten =
        HlsRewriter.rewrite(String.fromCharCodes(bytes), effective);
    res.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
    res.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    res.add(Uint8List.fromList(rewritten.codeUnits));
    await res.close();
  }

  Future<void> _serveSegment(
      HttpResponse res, Map<String, String> params) async {
    final u = params['u'];
    if (u == null) {
      res.statusCode = 404;
      await res.close();
      return;
    }
    var bytes = await fetchBytes(HlsRewriter.decodeUrl(u));

    final keyParam = params['k'];
    final iv = HlsRewriter.decodeIv(params['iv']);
    if (keyParam != null && iv != null) {
      final keyUrl = HlsRewriter.decodeUrl(keyParam);
      final key = _keys[keyUrl] ??= await _fetchKey(keyUrl);
      bytes = decryptAes128Cbc(key, iv, bytes);
    }

    res.headers.contentType = ContentType('video', 'mp2t');
    res.add(bytes);
    await res.close();
  }

  Future<Uint8List> _fetchKey(String url) async {
    final bytes = await fetchBytes(url);
    if (bytes.length != 16) {
      throw StateError('AES-128 key at $url is ${bytes.length} bytes, not 16');
    }
    return bytes;
  }

  /// Pass-through key fetch for methods we can't decrypt (SAMPLE-AES).
  Future<void> _serveKey(HttpResponse res, String? u) async {
    if (u == null) {
      res.statusCode = 404;
      await res.close();
      return;
    }
    final bytes = await fetchBytes(HlsRewriter.decodeUrl(u));
    res.headers.contentType = ContentType('application', 'octet-stream');
    res.add(bytes);
    await res.close();
  }

  /// Standard HLS segment encryption: AES-128-CBC with PKCS7 padding.
  static Uint8List decryptAes128Cbc(
      Uint8List key, Uint8List iv, Uint8List data) {
    if (data.isEmpty || data.length % 16 != 0) {
      throw StateError(
          'ciphertext length ${data.length} is not a multiple of 16');
    }
    final cipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
      ..init(
          false,
          PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
              ParametersWithIV(KeyParameter(key), iv), null));
    return cipher.process(data);
  }
}
