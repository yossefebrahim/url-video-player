import 'dart:convert';
import 'dart:typed_data';

/// Pure playlist-rewriting logic for the live-HLS cast proxy (kept free of
/// dart:io / Flutter so it unit-tests on the host, like [CencDecryptor]).
///
/// Rewrites an HLS playlist so every URL the receiver would fetch points back
/// at the phone proxy instead of the origin:
///
///  * master playlists — variant / `#EXT-X-MEDIA` / I-frame URIs become
///    `playlist.m3u8?u=<b64url(upstream)>`;
///  * media playlists — segment URIs become
///    `seg.ts?u=<b64url(upstream)>[&k=<b64url(keyUri)>&iv=<32-hex>]`.
///
/// **AES-128 is terminated on the phone**: `#EXT-X-KEY:METHOD=AES-128` lines
/// are dropped from the output and each segment carries its key URI + final
/// 16-byte IV (explicit `IV=0x…` attr, else the media-sequence number per the
/// HLS spec) so the proxy can decrypt and serve clear TS. The receiver never
/// sees the key and never needs the origin's User-Agent. Other methods
/// (SAMPLE-AES) can't be decrypted segment-wise; their key line survives with
/// the key URI proxied through `key?u=…` as a best effort.
///
/// `#EXT-X-PROGRAM-DATE-TIME` lines are stripped: these obfuscated live
/// channels carry bogus PDT values (they overflow ExoPlayer's Int64 locally —
/// see the handoff notes) and Shaka only needs PDT for multi-variant sync,
/// which single-variant live channels don't use.
class HlsRewriter {
  /// Rewrites [playlist] (fetched from [playlistUri]) into its proxied form.
  /// Emitted references are relative (`seg.ts?…`), so they resolve correctly
  /// no matter which path the proxy served the playlist from.
  static String rewrite(String playlist, Uri playlistUri) {
    final isMaster = playlist.contains('#EXT-X-STREAM-INF');
    final out = StringBuffer();

    // Active decryption state while walking a media playlist.
    String? keyUri; // absolute AES-128 key URL, null when clear
    Uint8List? keyIv; // explicit IV attr, null → derive from mediaSequence
    var mediaSequence = 0;
    var expectVariantUri = false;

    for (final rawLine in const LineSplitter().convert(playlist)) {
      final line = rawLine.trimRight();

      if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        mediaSequence =
            int.tryParse(line.split(':')[1].trim()) ?? mediaSequence;
        out.writeln(line);
      } else if (line.startsWith('#EXT-X-KEY:') ||
          line.startsWith('#EXT-X-SESSION-KEY:')) {
        final attrs = _attributes(line.substring(line.indexOf(':') + 1));
        final method = attrs['METHOD'] ?? 'NONE';
        if (method == 'NONE') {
          keyUri = null;
          keyIv = null;
          out.writeln(line);
        } else if (method == 'AES-128') {
          // A non-NONE method without a URI is malformed (RFC 8216 requires it):
          // reset key state rather than leaving the previous key active, which
          // would decrypt following segments with the wrong key into garbage.
          if (attrs['URI'] == null) {
            keyUri = null;
            keyIv = null;
          } else {
            keyUri = playlistUri.resolve(attrs['URI']!).toString();
            keyIv = _parseIvAttr(attrs['IV']);
          }
          // Dropped: the proxy decrypts, so the output stream is clear.
        } else {
          // SAMPLE-AES etc — can't decrypt here; at least proxy the key fetch.
          keyUri = null;
          keyIv = null;
          final uri = attrs['URI'];
          out.writeln(uri == null
              ? line
              : line.replaceFirst('URI="$uri"',
                  'URI="key?u=${_b64(playlistUri.resolve(uri))}"'));
        }
      } else if (line.startsWith('#EXT-X-MAP:')) {
        final attrs = _attributes(line.substring('#EXT-X-MAP:'.length));
        final uri = attrs['URI'];
        if (uri == null) {
          out.writeln(line);
        } else {
          // A MAP under an AES-128 key should carry an explicit IV (the
          // media-sequence rule doesn't apply to it); fall back to the current
          // sequence IV so the proxy still DECRYPTS it rather than emitting a
          // bare ref that serves the init segment still-encrypted.
          final iv = keyUri == null ? null : (keyIv ?? _sequenceIv(mediaSequence));
          final target =
              _segmentRef(playlistUri.resolve(uri), keyUri: keyUri, iv: iv);
          out.writeln(line.replaceFirst('URI="$uri"', 'URI="$target"'));
        }
      } else if (line.startsWith('#EXT-X-PROGRAM-DATE-TIME:')) {
        // Stripped on purpose — bogus in these streams (see class docs).
      } else if (line.startsWith('#EXT-X-STREAM-INF:')) {
        expectVariantUri = true;
        out.writeln(line);
      } else if (line.startsWith('#EXT-X-I-FRAME-STREAM-INF:') ||
          line.startsWith('#EXT-X-MEDIA:')) {
        final attrs = _attributes(line.substring(line.indexOf(':') + 1));
        final uri = attrs['URI'];
        out.writeln(uri == null
            ? line
            : line.replaceFirst('URI="$uri"',
                'URI="playlist.m3u8?u=${_b64(playlistUri.resolve(uri))}"'));
      } else if (line.isEmpty || line.startsWith('#')) {
        out.writeln(line);
      } else {
        // A URI line: a variant in a master, a segment in a media playlist.
        final upstream = playlistUri.resolve(line.trim());
        if (isMaster || expectVariantUri) {
          expectVariantUri = false;
          out.writeln('playlist.m3u8?u=${_b64(upstream)}');
        } else {
          final iv = keyUri == null
              ? null
              : (keyIv ?? _sequenceIv(mediaSequence));
          out.writeln(_segmentRef(upstream, keyUri: keyUri, iv: iv));
          mediaSequence++;
        }
      }
    }
    return out.toString();
  }

  static String _segmentRef(Uri upstream, {String? keyUri, Uint8List? iv}) {
    final b = StringBuffer('seg.ts?u=${_b64(upstream)}');
    if (keyUri != null && iv != null) {
      b.write('&k=${_b64(Uri.parse(keyUri))}');
      b.write('&iv=${_hex(iv)}');
    }
    return b.toString();
  }

  /// HLS spec: a segment with no `IV` attribute uses its media-sequence number
  /// as a 128-bit big-endian IV.
  static Uint8List _sequenceIv(int sequence) {
    final iv = Uint8List(16);
    for (var i = 0; i < 8; i++) {
      iv[15 - i] = (sequence >> (8 * i)) & 0xff;
    }
    return iv;
  }

  /// Parses `IV=0x9F…` (hex, any case) into 16 bytes; null when absent/bad.
  static Uint8List? _parseIvAttr(String? attr) {
    if (attr == null) return null;
    var h = attr.toLowerCase();
    if (h.startsWith('0x')) h = h.substring(2);
    if (h.length > 32 || h.length % 2 != 0) return null;
    h = h.padLeft(32, '0');
    try {
      return Uint8List.fromList([
        for (var i = 0; i < 32; i += 2)
          int.parse(h.substring(i, i + 2), radix: 16)
      ]);
    } on FormatException {
      return null;
    }
  }

  /// `METHOD=AES-128,URI="…",IV=0x…` → {METHOD: AES-128, URI: …, IV: 0x…}
  /// (quotes stripped from quoted values).
  static Map<String, String> _attributes(String list) {
    final out = <String, String>{};
    for (final m
        in RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)').allMatches(list)) {
      var v = m.group(2)!;
      if (v.startsWith('"') && v.endsWith('"') && v.length >= 2) {
        v = v.substring(1, v.length - 1);
      }
      out[m.group(1)!] = v;
    }
    return out;
  }

  /// URL-safe, padding-less base64 of an absolute URL (query-string friendly).
  static String _b64(Uri url) =>
      base64Url.encode(utf8.encode(url.toString())).replaceAll('=', '');

  /// Inverse of [_b64] — used by the proxy to recover the upstream URL.
  static String decodeUrl(String b64) =>
      utf8.decode(base64Url.decode(base64Url.normalize(b64)));

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Parses a 32-char hex IV back into 16 bytes (proxy side).
  static Uint8List? decodeIv(String? hex) {
    if (hex == null || hex.length != 32) return null;
    try {
      return Uint8List.fromList([
        for (var i = 0; i < 32; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16)
      ]);
    } on FormatException {
      return null;
    }
  }
}
