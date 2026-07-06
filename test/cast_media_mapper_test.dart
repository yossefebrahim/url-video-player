import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vp/models/video_item.dart';
import 'package:vp/services/cast_media_mapper.dart';
import 'package:vp/services/clear_key.dart';

VideoItem _item(String url, {String? ua, PlayerMode mode = PlayerMode.native}) =>
    VideoItem(title: 'Match', url: url, userAgent: ua, mode: mode);

// A real MBC-style ClearKey DASH hand-off (encrypted series).
const _clearKeyUrl =
    'https://h.tld/i.mpd###3JiNt9Bxu6h/Jq7rdNagKA:74bp3RHIScabj0+anXgz1g';

void main() {
  group('CastMediaMapper.eligibility', () {
    test('plain stream is castable', () {
      expect(CastMediaMapper.eligibility(_item('https://h.tld/a.mp4')),
          CastEligibility.ok);
    });

    test('web-mode item is not castable', () {
      expect(
          CastMediaMapper.eligibility(
              _item('https://h.tld/embed', mode: PlayerMode.web)),
          CastEligibility.webMode);
    });

    test('ClearKey CENC DASH is castable via the on-device decrypt proxy', () {
      expect(CastMediaMapper.eligibility(_item(_clearKeyUrl)),
          CastEligibility.ok);
    });

    test('encrypted but non-DASH (or unparseable key) stays deferred', () {
      // Valid key but an .m3u8 — not a CENC DASH the proxy rewrites.
      expect(
          CastMediaMapper.eligibility(_item(
              'https://h.tld/x.m3u8###3JiNt9Bxu6h/Jq7rdNagKA:74bp3RHIScabj0+anXgz1g')),
          CastEligibility.drmDeferred);
    });
  });

  group('CastMediaMapper container mapping', () {
    test('contentType per resolved format', () {
      expect(CastMediaMapper.contentTypeFor('dash'), 'application/dash+xml');
      expect(
          CastMediaMapper.contentTypeFor('hls'), 'application/vnd.apple.mpegurl');
      expect(CastMediaMapper.contentTypeFor(null), 'video/mp4');
    });

    test('live .json HLS → LIVE; m3u8 VOD and MP4 → BUFFERED', () {
      expect(
          CastMediaMapper.streamTypeFor(
              'hls', 'https://www.nazika.shop/x1/54_42.json?token=a'),
          CastMediaStreamType.live);
      expect(CastMediaMapper.streamTypeFor('hls', 'https://h.tld/a.m3u8'),
          CastMediaStreamType.buffered);
      expect(CastMediaMapper.streamTypeFor(null, 'https://h.tld/a.mp4'),
          CastMediaStreamType.buffered);
    });
  });

  group('CastMediaMapper.mediaInfoFor', () {
    test('maps url + content type; forwards User-Agent in customData', () {
      final item = _item('https://h.tld/a.mp4', ua: 'MyUA/1.0');
      final info =
          CastMediaMapper.mediaInfoFor(item, ClearKeyResolver.resolve(item.url));
      expect(info.contentId, 'https://h.tld/a.mp4');
      expect(info.contentType, 'video/mp4');
      expect(info.streamType, CastMediaStreamType.buffered);
      expect(info.customData?['userAgent'], 'MyUA/1.0');
    });

    test('ClearKey JSON is forwarded in customData (Phase-2 receiver)', () {
      final item = _item(_clearKeyUrl);
      final info =
          CastMediaMapper.mediaInfoFor(item, ClearKeyResolver.resolve(item.url));
      expect(info.contentId, 'https://h.tld/i.mpd');
      expect(info.contentType, 'application/dash+xml');
      expect(info.customData?['clearKey'], isNotNull);
    });

    test('no UA and no DRM → null customData', () {
      final item = _item('https://h.tld/a.mp4');
      final info =
          CastMediaMapper.mediaInfoFor(item, ClearKeyResolver.resolve(item.url));
      expect(info.customData, isNull);
    });
  });
}
