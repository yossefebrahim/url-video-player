import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A stream URL split into its playable manifest and optional decryption config.
class ResolvedStream {
  final String url;

  /// ClearKey EME JSON (`{"keys":[…],"type":"temporary"}`) when the source was
  /// CENC-encrypted with an inline key; null for plain streams.
  final String? clearKeyJson;

  /// 'dash' | 'hls' | null (let the player sniff).
  final String? format;

  /// Raw 16-byte content key of the first `k:kid` pair — used by the on-device
  /// CENC decrypt proxy when casting DRM series. Null if absent/malformed.
  final Uint8List? keyBytes;

  ResolvedStream(this.url, {this.clearKeyJson, this.format, this.keyBytes});

  bool get isEncrypted => clearKeyJson != null;

  /// Same stream with the container [format] overridden (used after sniffing).
  ResolvedStream withFormat(String? format) => ResolvedStream(url,
      clearKeyJson: clearKeyJson, format: format, keyBytes: keyBytes);
}

/// Resolves the `<manifestUrl>###<k>:<kid>` scheme used by the t4w ecosystem for
/// ClearKey-encrypted DASH/HLS streams.
///
/// Faithful port of `info.t4w.vp.view.VideoPlayer` (`###` split + `tmpSize211` +
/// `sKey6064`): the part after `###` is one or more `k:kid` pairs (pipe-separated
/// for multi-key), each normalized to padding-less base64, assembled into the
/// ClearKey JSON that ExoPlayer's LocalMediaDrmCallback consumes.
///
/// Live channels in this ecosystem are handed off with **obfuscated extensions**
/// (e.g. `…/54_42.json`, segments disguised as `.jpg`) so the URL alone can't
/// reveal the container. [needsSniff] + [sniffFormat] probe the bytes for those.
class ClearKeyResolver {
  /// Extensions we can hand straight to a progressive player without probing.
  static const _progressiveExts = <String>{
    'mp4', 'm4v', 'mkv', 'webm', 'mov', 'avi', 'ts', 'flv', '3gp', '3g2',
    'mp3', 'm4a', 'aac', 'ogg', 'oga', 'opus', 'wav', 'mpeg', 'mpg',
    'm2ts', 'mts', 'wmv', 'mpd', 'm3u8',
  };

  static ResolvedStream resolve(String rawUrl) {
    var url = rawUrl;
    String? clearKeyJson;

    Uint8List? keyBytes;
    final marker = rawUrl.indexOf('###');
    if (marker >= 0) {
      url = rawUrl.substring(0, marker);
      final keyStr = rawUrl.substring(marker + 3);
      clearKeyJson = _buildClearKeyJson(keyStr);
      keyBytes = _firstKeyBytes(keyStr);
    }

    return ResolvedStream(url,
        clearKeyJson: clearKeyJson,
        format: _formatFromUrl(url),
        keyBytes: keyBytes);
  }

  /// Raw 16-byte content key of the first `k:kid` pair (for the CENC proxy).
  static Uint8List? _firstKeyBytes(String keyStr) {
    try {
      final k = keyStr.split('|').first.split(':').first.trim();
      final std = k.replaceAll('-', '+').replaceAll('_', '/');
      final bytes = base64.decode(base64.normalize(std));
      return bytes.length == 16 ? Uint8List.fromList(bytes) : null;
    } catch (_) {
      return null;
    }
  }

  /// Container hint from the URL string alone (null when the extension is opaque).
  static String? _formatFromUrl(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('.mpd') || lower.contains('dash')) return 'dash';
    if (lower.contains('.m3u8')) return 'hls';
    return null;
  }

  /// True when the URL gave no usable container hint and the extension isn't a
  /// known progressive media file — i.e. worth a byte-level [sniffFormat] probe
  /// (the disguised `…/54_42.json` HLS playlists Ostora hands off for live TV).
  static bool needsSniff(ResolvedStream stream) {
    if (stream.format != null) return false;
    final ext = _extensionOf(stream.url);
    return ext == null || !_progressiveExts.contains(ext);
  }

  /// Fetches the head of [url] and classifies the manifest by its actual content
  /// rather than its extension: `#EXTM3U` (or an mpegurl content-type) → 'hls';
  /// an MPD/XML root (or dash+xml content-type) → 'dash'; otherwise null.
  ///
  /// Best-effort: returns null on any network/timeout/parse error so the caller
  /// can fall back gracefully.
  static Future<String?> sniffFormat(String url, {Map<String, String>? headers}) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      final request = await client.getUrl(Uri.parse(url));
      headers?.forEach(request.headers.set);
      final response = await request.close().timeout(const Duration(seconds: 10));

      // Content-Type is the most reliable signal when the server sets it.
      final mime = response.headers.contentType?.mimeType.toLowerCase() ?? '';
      if (mime.contains('mpegurl')) return 'hls';
      if (mime.contains('dash+xml')) return 'dash';

      // Otherwise sniff the first bytes of the body.
      final head = (await _readHead(response)).trimLeft();
      if (head.startsWith('#EXTM3U')) return 'hls';
      if (head.startsWith('<?xml') || head.contains('<MPD')) return 'dash';
      return null;
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  /// Reads up to ~2 KB from the response, enough to see a manifest's first line.
  static Future<String> _readHead(HttpClientResponse response) async {
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length >= 2048) break;
    }
    return utf8.decode(bytes.take(2048).toList(), allowMalformed: true);
  }

  /// Lower-cased file extension of the URL path (query/fragment stripped), or
  /// null when the last path segment has none.
  static String? _extensionOf(String url) {
    var path = url;
    final query = path.indexOf('?');
    if (query >= 0) path = path.substring(0, query);
    final fragment = path.indexOf('#');
    if (fragment >= 0) path = path.substring(0, fragment);

    final slash = path.lastIndexOf('/');
    final segment = slash >= 0 ? path.substring(slash + 1) : path;
    final dot = segment.lastIndexOf('.');
    if (dot < 0 || dot == segment.length - 1) return null;
    return segment.substring(dot + 1).toLowerCase();
  }

  /// Mirror of `tmpSize211`. Returns null if the key string is malformed.
  static String? _buildClearKeyJson(String keyStr) {
    try {
      final entries = <String>[];
      for (final pair in keyStr.split('|')) {
        final kv = pair.split(':');
        if (kv.length < 2) {
          throw const FormatException('expected k:kid');
        }
        final k = _normalizeBase64(kv[0].trim());
        final kid = _normalizeBase64(kv[1].trim());
        entries.add('{"kty":"oct","k":"$k","kid":"$kid","alg":"A128KW"}');
      }
      if (entries.isEmpty) return null;
      return '{"keys":[${entries.join(',')}],"type":"temporary"}';
    } catch (_) {
      return null;
    }
  }

  /// Mirror of `sKey6064`: if [value] is already valid base64 keep it, otherwise
  /// base64-encode its bytes; either way strip trailing '=' padding.
  static String _normalizeBase64(String value) {
    var v = value.trim();
    if (v.isEmpty) return '';

    var isBase64 = false;
    try {
      final decoded = base64.decode(base64.normalize(v));
      final reencoded = base64.encode(decoded);
      isBase64 = reencoded.replaceAll('=', '') == v.replaceAll('=', '');
    } catch (_) {
      isBase64 = false;
    }
    if (!isBase64) {
      v = base64.encode(utf8.encode(v));
    }
    // EME ClearKey (JWK) requires base64url without padding. On Android SDK >= 27
    // media3's ClearKeyUtil passes the JSON to the framework CDM unchanged, so we
    // must emit base64url here (the '+'/'/' of standard base64 are rejected).
    v = v.replaceAll('+', '-').replaceAll('/', '_');
    while (v.endsWith('=')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }
}
