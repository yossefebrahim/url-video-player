import 'package:flutter_test/flutter_test.dart';
import 'package:vp/models/video_item.dart';

void main() {
  group('VideoItem', () {
    test('map round-trips all fields', () {
      final item = VideoItem(
        id: 7,
        title: 'Clip',
        url: 'https://h.tld/a.mp4',
        userAgent: 'UA/1',
        mode: PlayerMode.web,
        source: VideoSource.deepLink,
        thumbnailPath: '/tmp/x.jpg',
        durationMs: 90000,
        width: 1920,
        height: 1080,
        favorite: true,
        addedAt: 1234567890,
      );
      final restored = VideoItem.fromMap(item.toMap());
      expect(restored.id, 7);
      expect(restored.title, 'Clip');
      expect(restored.url, 'https://h.tld/a.mp4');
      expect(restored.userAgent, 'UA/1');
      expect(restored.mode, PlayerMode.web);
      expect(restored.source, VideoSource.deepLink);
      expect(restored.thumbnailPath, '/tmp/x.jpg');
      expect(restored.durationMs, 90000);
      expect(restored.width, 1920);
      expect(restored.height, 1080);
      expect(restored.favorite, isTrue);
      expect(restored.addedAt, 1234567890);
    });

    test('equality is by URL', () {
      final a = VideoItem(title: 'A', url: 'https://x/y');
      final b = VideoItem(title: 'B different', url: 'https://x/y');
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('durationLabel formats hours and minutes', () {
      expect(VideoItem(title: '', url: 'u', durationMs: 247000).durationLabel,
          '04:07');
      expect(
          VideoItem(title: '', url: 'u', durationMs: 3661000).durationLabel,
          '1:01:01');
      expect(VideoItem(title: '', url: 'u').durationLabel, isNull);
    });

    test('resolutionLabel formats width x height', () {
      expect(
          VideoItem(title: '', url: 'u', width: 1280, height: 720)
              .resolutionLabel,
          '1280×720');
      expect(VideoItem(title: '', url: 'u').resolutionLabel, isNull);
    });
  });
}
