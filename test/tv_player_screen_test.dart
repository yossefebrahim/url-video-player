import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vp/screens/tv_player_screen.dart';

/// `BetterPlayerAsmsTrack(id, width, height, bitrate, frameRate, codecs, mime)`.
BetterPlayerAsmsTrack _track(int height, {int bitrate = 0}) =>
    BetterPlayerAsmsTrack('', 0, height, bitrate, 0, '', '');

void main() {
  group('clampSeekTarget', () {
    const dur = Duration(minutes: 1);

    test('adds a positive delta within bounds', () {
      expect(clampSeekTarget(const Duration(seconds: 5), dur,
          const Duration(seconds: 10)),
          const Duration(seconds: 15));
    });

    test('clamps to zero at the start (no negative position)', () {
      expect(
          clampSeekTarget(const Duration(seconds: 3), dur,
              const Duration(seconds: -10)),
          Duration.zero);
    });

    test('clamps to the duration at the end', () {
      expect(
          clampSeekTarget(const Duration(seconds: 58), dur,
              const Duration(seconds: 10)),
          dur);
    });

    test('a live / unknown duration has no upper bound', () {
      // null and non-positive durations both mean "no end to clamp to".
      final pos = const Duration(hours: 2);
      expect(clampSeekTarget(pos, null, const Duration(seconds: 10)),
          const Duration(hours: 2, seconds: 10));
      expect(clampSeekTarget(pos, Duration.zero, const Duration(seconds: 10)),
          const Duration(hours: 2, seconds: 10));
    });
  });

  group('sortedQualityTracks', () {
    test('drops the empty auto placeholder, dedupes and sorts high→low', () {
      final tracks = [
        BetterPlayerAsmsTrack.defaultTrack(), // height 0 → dropped
        _track(720),
        _track(1080),
        _track(720, bitrate: 999), // duplicate height → dropped
        _track(480),
      ];
      final out = sortedQualityTracks(tracks);
      expect(out.map((t) => t.height).toList(), [1080, 720, 480]);
    });

    test('empty when there are no real tracks', () {
      expect(sortedQualityTracks([BetterPlayerAsmsTrack.defaultTrack()]),
          isEmpty);
    });
  });

  group('qualityLabel', () {
    test('formats a resolution and falls back to Auto', () {
      expect(qualityLabel(_track(1080)), '1080p');
      expect(qualityLabel(BetterPlayerAsmsTrack.defaultTrack()), 'Auto');
    });
  });

  group('formatMediaTime', () {
    test('mm:ss under an hour, h:mm:ss over', () {
      expect(formatMediaTime(const Duration(seconds: 5)), '00:05');
      expect(formatMediaTime(const Duration(minutes: 3, seconds: 9)), '03:09');
      expect(
          formatMediaTime(const Duration(hours: 1, minutes: 2, seconds: 3)),
          '1:02:03');
    });
  });
}
