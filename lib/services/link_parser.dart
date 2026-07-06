import 'dart:convert';

import '../models/video_item.dart';

/// Resolves incoming intents into a playable [ParsedLink].
///
/// The custom-scheme format (`urlplayer://` / `urlvplayer://`) is a faithful
/// re-implementation of the original `info.t4w.vp.view.Scheme` activity so that
/// links handed off by sibling apps (e.g. Ostora) resolve identically:
///
///   host ends with "play" -> native player, obfuscated `url` param
///   host ends with "web"  -> web player,    obfuscated `url` param
///   otherwise             -> web player,    plain URL-decoded `url` param
///
/// The obfuscated `url` is: URL-safe Base64  ->  bytes  ->  XOR(key)  ->  URLDecode.
class LinkParser {
  static const _xorKey = 'jMkn9kbN4Xr8V3NKXdsRA7QwY4Ars9mv4Xr8V3NKXYFhbYgw';

  /// Parse a payload delivered by the native deep-link channel.
  static ParsedLink? parsePayload(Map<dynamic, dynamic> payload) {
    final type = payload['type'] as String?;
    if (type == 'extra') {
      // Explicit-component hand-off: "url" is a plain URL, optionally prefixed
      // with a "urlvplayer://" / "urlplayer://" marker (NOT the obfuscated form).
      var url = payload['url'] as String?;
      if (url == null || url.isEmpty) return null;
      for (final marker in const ['urlvplayer://', 'urlplayer://']) {
        if (url!.startsWith(marker)) url = url.substring(marker.length);
      }
      url = _sanitizeUrl(url!);
      if (url.isEmpty) return null;
      var agent = payload['agent'] as String?;
      if (agent != null && (agent.isEmpty || agent == 'Web Player')) {
        agent = null;
      }
      return ParsedLink(
        item: VideoItem(
          title: titleFromUrl(url),
          url: url,
          userAgent: agent,
          mode: PlayerMode.native,
          source: VideoSource.deepLink,
        ),
        autoPlay: true,
      );
    }
    if (type == 'view') {
      final uriStr = payload['uri'] as String?;
      if (uriStr == null || uriStr.isEmpty) return null;
      return parseUri(uriStr);
    } else if (type == 'send') {
      final text = payload['text'] as String?;
      if (text == null || text.isEmpty) return null;
      final url = _firstUrl(text);
      if (url == null) return null;
      // A shared URL pre-fills the form rather than auto-playing.
      return ParsedLink(
        item: VideoItem(
          title: titleFromUrl(url),
          url: url,
          mode: PlayerMode.native,
          source: VideoSource.shared,
        ),
        autoPlay: false,
      );
    }
    return null;
  }

  /// Parse a raw intent URI string.
  static ParsedLink? parseUri(String uriStr) {
    Uri uri;
    try {
      uri = Uri.parse(uriStr.trim());
    } catch (_) {
      return null;
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'urlplayer' || scheme == 'urlvplayer') {
      return _parseCustomScheme(uri);
    }
    // Only schemes the bundled ExoPlayer can actually play and that the
    // manifest's VIEW filter routes to us (no rtmp/rtsp — those need extra
    // ExoPlayer modules we don't ship).
    if (scheme == 'http' ||
        scheme == 'https' ||
        scheme == 'file' ||
        scheme == 'content') {
      // A direct video URL opened via "open with" / VIEW.
      return ParsedLink(
        item: VideoItem(
          title: titleFromUrl(uriStr),
          url: uriStr,
          mode: PlayerMode.native,
          source: VideoSource.openWith,
        ),
        autoPlay: true,
      );
    }
    return null;
  }

  static ParsedLink? _parseCustomScheme(Uri uri) {
    final host = uri.host.toLowerCase();
    final rawUrlParam = _rawQueryParam(uri, 'url');
    if (rawUrlParam == null || rawUrlParam.isEmpty) return null;

    String? agent = _rawQueryParam(uri, 'agent') ??
        _rawQueryParam(uri, 'userAgent') ??
        _rawQueryParam(uri, 'user_agent');
    if (agent != null) {
      var a = agent;
      // Mirror the original's second URLDecoder.decode pass.
      try {
        a = Uri.decodeQueryComponent(a);
      } catch (_) {}
      agent = (a.isEmpty || a == 'Web Player') ? null : a;
    }

    String? resolved;
    PlayerMode mode;
    if (host.endsWith('play')) {
      resolved = _decodeObfuscated(rawUrlParam);
      mode = PlayerMode.native;
    } else if (host.endsWith('web')) {
      resolved = _decodeObfuscated(rawUrlParam);
      mode = PlayerMode.web;
    } else {
      try {
        resolved = Uri.decodeQueryComponent(rawUrlParam);
      } catch (_) {
        resolved = rawUrlParam;
      }
      mode = PlayerMode.web;
    }
    if (resolved == null || resolved.isEmpty) return null;
    resolved = _sanitizeUrl(resolved);
    if (resolved.isEmpty) return null;

    return ParsedLink(
      item: VideoItem(
        title: titleFromUrl(resolved),
        url: resolved,
        userAgent: agent,
        mode: mode,
        source: VideoSource.deepLink,
      ),
      autoPlay: true,
    );
  }

  // Schemes this app can actually play (parseUri gates on the same set). Used
  // only to decide whether a decoded URL is already well-formed; matching one
  // of these at the START means "leave it alone".
  static final _knownScheme =
      RegExp(r'^(https?|file|content)://', caseSensitive: false);
  static final _httpScheme = RegExp(r'https?://', caseSensitive: false);

  /// Defensive guard on a decoded/handed-off URL: some senders (e.g. a newer
  /// Ostora build) prepend a few stray bytes before the real link — the app was
  /// seen storing `407<F>https://…/index.mpd`, which ExoPlayer rejects with
  /// `MalformedURLException: no protocol`. If the string doesn't already start
  /// with a playable scheme but an `http(s)://` appears further in, drop the
  /// leading junk. A no-op for well-formed URLs (including the `…###k:kid`
  /// ClearKey form and `file://`/`content://` links, whose scheme is at the
  /// start), and it never rewrites a later scheme inside a query string.
  static String _sanitizeUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty || _knownScheme.hasMatch(trimmed)) return trimmed;
    final m = _httpScheme.firstMatch(trimmed);
    return (m != null && m.start > 0) ? trimmed.substring(m.start) : trimmed;
  }

  /// URL-safe Base64 -> bytes -> XOR(key) -> URLDecode. Returns null on failure.
  static String? _decodeObfuscated(String param) {
    try {
      // Normalize to the URL-safe Base64 alphabet, mirroring the original's
      // `.replace('/', '_').replace(' ', '-').replace('+', '-')`.
      var s = param.replaceAll('/', '_').replaceAll(' ', '-').replaceAll('+', '-');
      s = s.replaceAll('=', '');
      final mod = s.length % 4;
      if (mod > 0) s = s + ('=' * (4 - mod));

      final bytes = base64Url.decode(s);
      final xored = String.fromCharCodes(bytes);
      final deobf = _xor(xored);
      return Uri.decodeQueryComponent(deobf);
    } catch (_) {
      return null;
    }
  }

  static String _xor(String s) {
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      buf.writeCharCode(s.codeUnitAt(i) ^ _xorKey.codeUnitAt(i % _xorKey.length));
    }
    return buf.toString();
  }

  /// Reads a query parameter mirroring Android's `Uri.getQueryParameter`:
  /// percent-decoded but with '+' preserved (uses [Uri.decodeComponent], not
  /// [Uri.decodeQueryComponent] which would turn '+' into a space).
  static String? _rawQueryParam(Uri uri, String key) {
    final q = uri.query;
    if (q.isEmpty) return null;
    for (final pair in q.split('&')) {
      final eq = pair.indexOf('=');
      if (eq < 0) continue;
      if (pair.substring(0, eq) == key) {
        final v = pair.substring(eq + 1);
        try {
          return Uri.decodeComponent(v);
        } catch (_) {
          return v;
        }
      }
    }
    return null;
  }

  static final _urlRegex =
      RegExp(r'https?://[^\s<>"]+', caseSensitive: false);

  static String? _firstUrl(String text) {
    final t = text.trim();
    final m = _urlRegex.firstMatch(t);
    if (m != null) return m.group(0);
    // A bare host/path with no scheme, e.g. "example.com/a.mp4".
    if (!t.contains(' ') && t.contains('.')) return t;
    return null;
  }

  static String titleFromUrl(String url) {
    try {
      final u = Uri.parse(url);
      final segs = u.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segs.isNotEmpty) {
        var name = segs.last;
        final dot = name.lastIndexOf('.');
        if (dot > 0) name = name.substring(0, dot);
        name = name.replaceAll(RegExp(r'[_\-+]+'), ' ').trim();
        if (name.isNotEmpty) return name;
      }
      if (u.host.isNotEmpty) return u.host;
    } catch (_) {}
    return 'Video';
  }
}
