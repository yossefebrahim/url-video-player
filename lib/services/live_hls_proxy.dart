import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'hls_key_decryptor.dart';

/// Local loopback HTTP proxy that makes the t4w / nazika live-TV HLS channels
/// (beIN etc.) playable by ExoPlayer.
///
/// Those playlists lock every segment with an **inline `data:` URI key**
/// (`#EXT-X-KEY:METHOD=AES-128,URI="data:text/plain;base64,ENC:…"`). ExoPlayer's
/// key loader can't open the `data:` scheme (`MalformedURLException: unknown
/// protocol: data` → Source error), and the key is additionally `ENC:`-wrapped.
///
/// The proxy sits in front of the player:
///  * `/pl` — fetches the origin playlist (with the required User-Agent, which
///    the origin demands), unwraps the `data:` key via [HlsKeyDecryptor], and
///    rewrites the `#EXT-X-KEY` line so its `URI` points at `/k` on this proxy
///    (raw 16-byte key). `METHOD=AES-128` and `IV` are preserved, so **ExoPlayer
///    still performs the AES-128 decryption natively**. Segment URIs are left
///    absolute at the origin CDN (which serves them with no headers at all), so
///    only the small playlist + key round-trip through the phone.
///  * `/k`  — returns the raw key bytes carried inline in the query.
///
/// Live playlists refresh: ExoPlayer re-requests `/pl` and the proxy re-fetches
/// and re-rewrites each time. The server is loopback-only and lazily started.
class LiveHlsProxy {
  LiveHlsProxy._();
  static final LiveHlsProxy instance = LiveHlsProxy._();

  HttpServer? _server;
  int _port = 0;
  HttpClient? _client;

  Future<void> _ensureStarted() async {
    if (_server != null) return;
    _client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _port = server.port;
    _server = server;
    server.listen(_handle, onError: (_) {});
  }

  /// Returns a loopback playlist URL for [originUrl] that ExoPlayer can play,
  /// carrying the [userAgent] the origin requires to serve its playlist.
  Future<String> wrap(String originUrl, {String? userAgent}) async {
    await _ensureStarted();
    final u = _enc(originUrl);
    final h =
        (userAgent == null || userAgent.isEmpty) ? '' : '&h=${_enc(userAgent)}';
    return 'http://127.0.0.1:$_port/pl?u=$u$h';
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      switch (req.uri.path) {
        case '/pl':
          await _servePlaylist(req);
          break;
        case '/k':
          _serveKey(req);
          break;
        default:
          res.statusCode = HttpStatus.notFound;
      }
    } catch (_) {
      try {
        res.statusCode = HttpStatus.internalServerError;
      } catch (_) {}
    } finally {
      await res.close().catchError((_) {});
    }
  }

  Future<void> _servePlaylist(HttpRequest req) async {
    final res = req.response;
    final u = req.uri.queryParameters['u'];
    if (u == null) {
      res.statusCode = HttpStatus.badRequest;
      return;
    }
    final origin = _dec(u);
    final h = req.uri.queryParameters['h'];
    final ua = h == null ? null : _dec(h);

    final playlist = await _fetch(origin, ua);
    if (playlist == null) {
      res.statusCode = HttpStatus.badGateway;
      return;
    }
    final rewritten = _rewrite(playlist, Uri.parse(origin), ua);
    res.statusCode = HttpStatus.ok;
    res.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
    res.headers.set(HttpHeaders.cacheControlHeader, 'no-cache, no-store');
    res.write(rewritten);
  }

  void _serveKey(HttpRequest req) {
    final res = req.response;
    final v = req.uri.queryParameters['v'];
    if (v == null) {
      res.statusCode = HttpStatus.badRequest;
      return;
    }
    try {
      final bytes = base64Url.decode(base64Url.normalize(v));
      res.statusCode = HttpStatus.ok;
      res.headers.contentType = ContentType('application', 'octet-stream');
      res.headers.set(HttpHeaders.cacheControlHeader, 'max-age=31536000');
      res.add(bytes);
    } catch (_) {
      res.statusCode = HttpStatus.badRequest;
    }
  }

  /// Hard cap on a fetched playlist body. Real HLS media/master playlists are a
  /// few KB; anything past this is a broken origin or a mis-served media file,
  /// which we refuse rather than accumulate into one giant String on the main
  /// isolate (this runs on every live playlist refresh for the whole session).
  static const int _maxPlaylistBytes = 4 * 1024 * 1024;

  Future<String?> _fetch(String url, String? ua) async {
    final client = _client;
    if (client == null) return null;
    try {
      final request = await client.getUrl(Uri.parse(url));
      if (ua != null && ua.isNotEmpty) {
        request.headers.set(HttpHeaders.userAgentHeader, ua);
      }
      final response = await request.close().timeout(const Duration(seconds: 12));
      if (response.statusCode >= 400) {
        await response.drain<void>().catchError((_) {});
        return null;
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        // Oversized: returning breaks the `await for`, which cancels the
        // subscription and tears down the connection — no drain needed.
        if (bytes.length > _maxPlaylistBytes) return null;
      }
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  /// Rewrites an HLS playlist so ExoPlayer can play it: inline `data:` keys are
  /// unwrapped and re-served from `/k`; a master playlist's variant URIs are
  /// routed back through `/pl` (so their media playlists get the same
  /// treatment); every other URI is absolutised to the origin.
  String _rewrite(String playlist, Uri base, String? ua) {
    final isMaster = playlist.contains('#EXT-X-STREAM-INF');
    final out = StringBuffer();
    var expectVariantUri = false;

    for (final raw in const LineSplitter().convert(playlist)) {
      final line = raw.trimRight();
      if (line.startsWith('#EXT-X-KEY:') ||
          line.startsWith('#EXT-X-SESSION-KEY:')) {
        out.writeln(_rewriteKeyLine(line));
      } else if (line.startsWith('#EXT-X-MAP:')) {
        out.writeln(_rewriteUriAttr(line, base));
      } else if (line.startsWith('#EXT-X-STREAM-INF:')) {
        expectVariantUri = true;
        out.writeln(line);
      } else if (line.startsWith('#EXT-X-MEDIA:') ||
          line.startsWith('#EXT-X-I-FRAME-STREAM-INF:')) {
        out.writeln(_rewriteVariantAttr(line, base, ua));
      } else if (line.isEmpty || line.startsWith('#')) {
        out.writeln(line);
      } else {
        // A URI line: a variant (master) or a segment (media playlist).
        final abs = base.resolve(line.trim());
        if (isMaster || expectVariantUri) {
          expectVariantUri = false;
          out.writeln(_variantUrl(abs.toString(), ua));
        } else {
          out.writeln(abs.toString());
        }
      }
    }
    return out.toString();
  }

  String _rewriteKeyLine(String line) {
    final attrs = _attrs(line.substring(line.indexOf(':') + 1));
    final method = attrs['METHOD'] ?? 'NONE';
    final uri = attrs['URI'];
    if (method == 'NONE' || uri == null || !uri.startsWith('data:')) {
      return line; // nothing to localise
    }
    final key = HlsKeyDecryptor.keyFromUri(uri);
    if (key == null) return line; // can't unwrap — leave as-is
    final local = 'http://127.0.0.1:$_port/k?v=${base64Url.encode(key).replaceAll('=', '')}';
    return line.replaceFirst('URI="$uri"', 'URI="$local"');
  }

  String _rewriteUriAttr(String line, Uri base) {
    final attrs = _attrs(line.substring(line.indexOf(':') + 1));
    final uri = attrs['URI'];
    if (uri == null || uri.startsWith('data:')) return line;
    return line.replaceFirst('URI="$uri"', 'URI="${base.resolve(uri)}"');
  }

  String _rewriteVariantAttr(String line, Uri base, String? ua) {
    final attrs = _attrs(line.substring(line.indexOf(':') + 1));
    final uri = attrs['URI'];
    if (uri == null) return line;
    return line.replaceFirst(
        'URI="$uri"', 'URI="${_variantUrl(base.resolve(uri).toString(), ua)}"');
  }

  String _variantUrl(String absolute, String? ua) {
    final h = (ua == null || ua.isEmpty) ? '' : '&h=${_enc(ua)}';
    return 'http://127.0.0.1:$_port/pl?u=${_enc(absolute)}$h';
  }

  /// `METHOD=AES-128,URI="…",IV=0x…` → {METHOD:…, URI:…, IV:…} (quotes stripped).
  static Map<String, String> _attrs(String list) {
    final out = <String, String>{};
    for (final m in RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)').allMatches(list)) {
      var v = m.group(2)!;
      if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
        v = v.substring(1, v.length - 1);
      }
      out[m.group(1)!] = v;
    }
    return out;
  }

  static String _enc(String s) =>
      base64Url.encode(utf8.encode(s)).replaceAll('=', '');
  static String _dec(String s) =>
      utf8.decode(base64Url.decode(base64Url.normalize(s)));
}
