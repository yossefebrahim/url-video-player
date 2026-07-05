import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/video_item.dart';

/// Local SQLite store for opened-URL history and favorites.
///
/// A single `history` table holds every opened/played URL keyed uniquely by
/// [VideoItem.url]; favorites are the subset with `favorite = 1`. Enrichment
/// metadata (thumbnail path, duration, resolution) is filled in lazily once a
/// video successfully initializes.
class HistoryDatabase {
  HistoryDatabase._([this._overridePath]);
  static final HistoryDatabase instance = HistoryDatabase._();

  /// A throwaway in-memory instance for tests.
  static HistoryDatabase inMemory() =>
      HistoryDatabase._(inMemoryDatabasePath);

  static const _dbName = 'url_video_player.db';
  static const _table = 'history';
  static const _version = 1;

  final String? _overridePath;
  Database? _db;

  Future<Database> get _database async {
    return _db ??= await _open();
  }

  Future<Database> _open() async {
    final path = _overridePath ?? p.join(await getDatabasesPath(), _dbName);
    return openDatabase(
      path,
      version: _version,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_table (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT,
            url TEXT NOT NULL UNIQUE,
            user_agent TEXT,
            mode TEXT,
            source TEXT,
            thumbnail_path TEXT,
            duration_ms INTEGER,
            width INTEGER,
            height INTEGER,
            favorite INTEGER NOT NULL DEFAULT 0,
            added_at INTEGER NOT NULL
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_history_added_at ON $_table(added_at DESC)');
        await db
            .execute('CREATE INDEX idx_history_favorite ON $_table(favorite)');
      },
    );
  }

  /// Inserts a freshly-opened item, or updates the existing row for the same
  /// URL (refreshing recency + metadata while preserving its favorite flag and
  /// any thumbnail already captured). Returns the row with its assigned id.
  Future<VideoItem> upsert(VideoItem item) async {
    final db = await _database;
    final existing = await db.query(_table,
        where: 'url = ?', whereArgs: [item.url], limit: 1);

    if (existing.isEmpty) {
      final id = await db.insert(_table, item.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
      return item.copyWith(id: id);
    }

    final prev = VideoItem.fromMap(existing.first);
    final merged = item.copyWith(
      id: prev.id,
      favorite: prev.favorite, // never lose a favorite on re-open
      // Keep previously enriched metadata unless the new item supplies it.
      thumbnailPath: item.thumbnailPath ?? prev.thumbnailPath,
      durationMs: item.durationMs ?? prev.durationMs,
      width: item.width ?? prev.width,
      height: item.height ?? prev.height,
      title: item.title.isNotEmpty ? item.title : prev.title,
      addedAt: item.addedAt,
    );
    await db.update(_table, merged.toMap(),
        where: 'id = ?', whereArgs: [prev.id]);
    return merged;
  }

  /// Patches enrichment metadata captured after playback started.
  Future<void> updateMetadata(
    String url, {
    String? thumbnailPath,
    int? durationMs,
    int? width,
    int? height,
  }) async {
    final db = await _database;
    final values = <String, Object?>{
      'thumbnail_path': ?thumbnailPath,
      'duration_ms': ?durationMs,
      'width': ?width,
      'height': ?height,
    };
    if (values.isEmpty) return;
    await db.update(_table, values, where: 'url = ?', whereArgs: [url]);
  }

  Future<List<VideoItem>> getHistory() async {
    final db = await _database;
    final rows = await db.query(_table, orderBy: 'added_at DESC');
    return rows.map(VideoItem.fromMap).toList();
  }

  Future<List<VideoItem>> getFavorites() async {
    final db = await _database;
    final rows = await db.query(_table,
        where: 'favorite = 1', orderBy: 'added_at DESC');
    return rows.map(VideoItem.fromMap).toList();
  }

  Future<bool> isFavorite(String url) async {
    final db = await _database;
    final rows = await db.query(_table,
        columns: ['favorite'], where: 'url = ?', whereArgs: [url], limit: 1);
    if (rows.isEmpty) return false;
    return (rows.first['favorite'] as int? ?? 0) == 1;
  }

  Future<void> setFavorite(String url, bool value) async {
    final db = await _database;
    await db.update(_table, {'favorite': value ? 1 : 0},
        where: 'url = ?', whereArgs: [url]);
  }

  Future<void> deleteByUrl(String url) async {
    final db = await _database;
    await db.delete(_table, where: 'url = ?', whereArgs: [url]);
  }

  /// Clears history but keeps favorited entries.
  Future<void> clearHistory() async {
    final db = await _database;
    await db.delete(_table, where: 'favorite = 0');
  }

  /// Removes all entries (history + favorites).
  Future<void> clearAll() async {
    final db = await _database;
    await db.delete(_table);
  }
}
