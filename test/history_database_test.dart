import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vp/models/video_item.dart';
import 'package:vp/services/history_database.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late HistoryDatabase db;

  setUp(() async {
    // sqflite opens ':memory:' as a single shared instance, so wipe it between
    // cases to keep each test isolated.
    db = HistoryDatabase.inMemory();
    await db.clearAll();
  });

  VideoItem item(String url, {String title = 'T', String? source}) => VideoItem(
        title: title,
        url: url,
        source: source ?? VideoSource.manual,
      );

  test('upsert inserts and assigns an id', () async {
    final saved = await db.upsert(item('https://a/1.mp4'));
    expect(saved.id, isNotNull);
    final history = await db.getHistory();
    expect(history, hasLength(1));
    expect(history.first.url, 'https://a/1.mp4');
  });

  test('re-opening the same URL de-dupes and preserves favorite + thumbnail',
      () async {
    final first = await db.upsert(item('https://a/1.mp4', title: 'First'));
    await db.setFavorite(first.url, true);
    await db.updateMetadata(first.url, thumbnailPath: '/tmp/t.jpg');

    // Re-open with a fresh item (no thumbnail, different title).
    await db.upsert(item('https://a/1.mp4', title: 'Second'));

    final history = await db.getHistory();
    expect(history, hasLength(1)); // de-duped by URL
    expect(history.first.favorite, isTrue); // favorite preserved
    expect(history.first.thumbnailPath, '/tmp/t.jpg'); // metadata preserved
    expect(history.first.title, 'Second'); // title refreshed
  });

  test('favorites are the favorite subset', () async {
    await db.upsert(item('https://a/1.mp4'));
    final b = await db.upsert(item('https://a/2.mp4'));
    await db.setFavorite(b.url, true);

    final favs = await db.getFavorites();
    expect(favs, hasLength(1));
    expect(favs.first.url, 'https://a/2.mp4');
    expect(await db.isFavorite('https://a/2.mp4'), isTrue);
    expect(await db.isFavorite('https://a/1.mp4'), isFalse);
  });

  test('updateMetadata patches duration and resolution', () async {
    final saved = await db.upsert(item('https://a/1.mp4'));
    await db.updateMetadata(saved.url,
        durationMs: 5000, width: 640, height: 360);
    final history = await db.getHistory();
    expect(history.first.durationMs, 5000);
    expect(history.first.resolutionLabel, '640×360');
  });

  test('clearHistory keeps favorites but removes the rest', () async {
    await db.upsert(item('https://a/1.mp4'));
    final b = await db.upsert(item('https://a/2.mp4'));
    await db.setFavorite(b.url, true);

    await db.clearHistory();
    final history = await db.getHistory();
    expect(history, hasLength(1));
    expect(history.first.url, 'https://a/2.mp4');
  });

  test('deleteByUrl removes a single row', () async {
    await db.upsert(item('https://a/1.mp4'));
    await db.upsert(item('https://a/2.mp4'));
    await db.deleteByUrl('https://a/1.mp4');
    final history = await db.getHistory();
    expect(history, hasLength(1));
    expect(history.first.url, 'https://a/2.mp4');
  });
}
