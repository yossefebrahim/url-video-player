import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';

import '../models/video_item.dart';
import 'clear_key.dart';

/// Whether the current item can be handed to a Cast receiver, and if not, why.
enum CastEligibility {
  /// Castable on the default receiver (plain MP4 / unencrypted HLS·DASH; the
  /// token'd live HLS is best-effort).
  ok,

  /// ClearKey-encrypted DASH series — needs the Phase-2 custom receiver.
  drmDeferred,

  /// Web/embedded player items have no direct media URL to hand off.
  webMode,
}

/// Maps our [VideoItem] onto a `flutter_chrome_cast` [GoogleCastMediaInformation].
///
/// Reuses [ClearKeyResolver] so the Cast path derives container/format exactly
/// like local playback does (including the disguised `…/54_42.json` HLS sniff).
/// See `docs/cast-to-tv-spec.md` for the honest default-receiver scope.
class CastMediaMapper {
  /// Classifies [item] for the Cast button's enable/disable + messaging.
  ///
  /// ClearKey **CENC DASH** series are now castable via the on-device decrypt
  /// proxy ([CastService] spins up a local server that decrypts and serves
  /// clear DASH). Only encrypted streams we can't proxy stay deferred.
  static CastEligibility eligibility(VideoItem item) {
    if (item.mode == PlayerMode.web) return CastEligibility.webMode;
    final r = ClearKeyResolver.resolve(item.url);
    if (r.isEncrypted) {
      final proxyable = r.keyBytes != null &&
          (r.format == 'dash' || r.url.toLowerCase().contains('.mpd'));
      if (!proxyable) return CastEligibility.drmDeferred;
    }
    return CastEligibility.ok;
  }

  /// Builds the Cast media, sniffing the container for opaque URLs (async).
  static Future<GoogleCastMediaInformation> buildMediaInfo(VideoItem item) async {
    var resolved = ClearKeyResolver.resolve(item.url);
    final ua = item.userAgent;
    final headers = <String, String>{
      if (ua != null && ua.isNotEmpty) 'User-Agent': ua,
    };
    if (ClearKeyResolver.needsSniff(resolved)) {
      final sniffed =
          await ClearKeyResolver.sniffFormat(resolved.url, headers: headers);
      resolved = resolved.withFormat(sniffed ?? 'hls');
    }
    return mediaInfoFor(item, resolved);
  }

  /// Pure mapping from an already-resolved stream to Cast media (unit-testable).
  static GoogleCastMediaInformation mediaInfoFor(
      VideoItem item, ResolvedStream resolved) {
    final ua = item.userAgent;
    final custom = <String, dynamic>{
      // The default receiver ignores customData; forwarded for the Phase-2
      // custom receiver (User-Agent can't be applied by Cast either way).
      if (ua != null && ua.isNotEmpty) 'userAgent': ua,
      if (resolved.clearKeyJson != null) 'clearKey': resolved.clearKeyJson,
    };
    return GoogleCastMediaInformation(
      contentId: resolved.url,
      streamType: streamTypeFor(resolved.format, resolved.url),
      contentType: contentTypeFor(resolved.format),
      metadata: GoogleCastGenericMediaMetadata(
        title: item.title.isEmpty ? 'Video' : item.title,
      ),
      customData: custom.isEmpty ? null : custom,
    );
  }

  /// MIME type Cast expects for each container.
  static String contentTypeFor(String? format) => switch (format) {
        'dash' => 'application/dash+xml',
        'hls' => 'application/vnd.apple.mpegurl',
        _ => 'video/mp4',
      };

  /// LIVE for the rolling `.json`/live HLS hand-offs; BUFFERED for VOD.
  static CastMediaStreamType streamTypeFor(String? format, String url) {
    if (format == 'hls' && _looksLive(url)) return CastMediaStreamType.live;
    return CastMediaStreamType.buffered;
  }

  static bool _looksLive(String url) {
    final u = url.toLowerCase();
    return u.contains('.json') || u.contains('/live') || u.contains('live/');
  }
}
