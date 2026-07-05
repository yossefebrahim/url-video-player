/// How a resolved link should be presented.
enum PlayerMode { native, web }

/// Where an entry originated from — shown as an "explanation" in history.
class VideoSource {
  static const manual = 'Added manually';
  static const deepLink = 'Opened via deep link';
  static const shared = 'Shared from another app';
  static const openWith = 'Opened with (external app)';
}

/// A single playable entry — used for the player form, history and favorites.
///
/// Persisted in the local SQLite `history` table with enrichment metadata
/// (thumbnail frame, duration and resolution) captured on first playback.
class VideoItem {
  final int? id; // DB row id (null until persisted)
  final String title;
  final String url;
  final String? userAgent;
  final PlayerMode mode;
  final String source; // human-readable origin, see [VideoSource]
  final String? thumbnailPath; // local cached poster frame
  final int? durationMs;
  final int? width;
  final int? height;
  final bool favorite;
  final int addedAt; // epoch millis

  VideoItem({
    this.id,
    required this.title,
    required this.url,
    this.userAgent,
    this.mode = PlayerMode.native,
    this.source = VideoSource.manual,
    this.thumbnailPath,
    this.durationMs,
    this.width,
    this.height,
    this.favorite = false,
    int? addedAt,
  }) : addedAt = addedAt ?? DateTime.now().millisecondsSinceEpoch;

  VideoItem copyWith({
    int? id,
    String? title,
    String? url,
    String? userAgent,
    PlayerMode? mode,
    String? source,
    String? thumbnailPath,
    int? durationMs,
    int? width,
    int? height,
    bool? favorite,
    int? addedAt,
  }) {
    return VideoItem(
      id: id ?? this.id,
      title: title ?? this.title,
      url: url ?? this.url,
      userAgent: userAgent ?? this.userAgent,
      mode: mode ?? this.mode,
      source: source ?? this.source,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      durationMs: durationMs ?? this.durationMs,
      width: width ?? this.width,
      height: height ?? this.height,
      favorite: favorite ?? this.favorite,
      addedAt: addedAt ?? this.addedAt,
    );
  }

  /// Human-friendly duration, e.g. "1:23:45" or "04:07".
  String? get durationLabel {
    final ms = durationMs;
    if (ms == null || ms <= 0) return null;
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  /// Resolution label, e.g. "1920×1080".
  String? get resolutionLabel {
    if (width == null || height == null || width == 0 || height == 0) {
      return null;
    }
    return '$width×$height';
  }

  // ---- SQLite mapping -------------------------------------------------------

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'title': title,
        'url': url,
        'user_agent': userAgent,
        'mode': mode.name,
        'source': source,
        'thumbnail_path': thumbnailPath,
        'duration_ms': durationMs,
        'width': width,
        'height': height,
        'favorite': favorite ? 1 : 0,
        'added_at': addedAt,
      };

  factory VideoItem.fromMap(Map<String, Object?> row) => VideoItem(
        id: row['id'] as int?,
        title: (row['title'] as String?) ?? '',
        url: (row['url'] as String?) ?? '',
        userAgent: row['user_agent'] as String?,
        mode: PlayerMode.values.firstWhere(
          (e) => e.name == row['mode'],
          orElse: () => PlayerMode.native,
        ),
        source: (row['source'] as String?) ?? VideoSource.manual,
        thumbnailPath: row['thumbnail_path'] as String?,
        durationMs: row['duration_ms'] as int?,
        width: row['width'] as int?,
        height: row['height'] as int?,
        favorite: (row['favorite'] as int? ?? 0) == 1,
        addedAt: (row['added_at'] as int?) ?? 0,
      );

  // Identity is the URL — used for de-duping history and toggling favorites.
  @override
  bool operator ==(Object other) => other is VideoItem && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

/// Result of resolving an incoming deep link / shared text.
class ParsedLink {
  final VideoItem item;

  /// Whether playback should start immediately (explicit hand-off) versus
  /// merely pre-filling the form (a shared URL the user may want to tweak).
  final bool autoPlay;

  ParsedLink({required this.item, required this.autoPlay});
}
