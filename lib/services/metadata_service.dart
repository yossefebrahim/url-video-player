import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Extracts a poster/thumbnail frame for a video URL and caches it on disk.
///
/// Delegates to the native `generateThumbnail` MethodChannel (Android
/// MediaMetadataRetriever), which works for direct files and progressive
/// streams. Sources it can't decode (e.g. some HLS streams) return null and are
/// handled gracefully by callers.
///
/// Cache entries are content-addressed by URL and treated as immutable: a given
/// video URL is assumed to always resolve to the same content, so there is no
/// TTL/invalidation. The filename uses a 64-bit FNV-1a digest of the URL (not
/// [String.hashCode], which is a 32-bit non-stable runtime hash prone to
/// filename collisions).
class MetadataService {
  MetadataService._();
  static final MetadataService instance = MetadataService._();

  static const MethodChannel _channel = MethodChannel('info.t4w.vp/deeplink');

  Directory? _cacheDir;

  Future<Directory> _thumbsDir() async {
    if (_cacheDir != null) return _cacheDir!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'thumbnails'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return _cacheDir = dir;
  }

  /// Stable 64-bit FNV-1a hash of [input] as a zero-padded hex string.
  static String _cacheKey(String input) {
    const fnvOffset = 0xcbf29ce484222325;
    const fnvPrime = 0x100000001b3;
    const mask = 0xFFFFFFFFFFFFFFFF;
    var hash = fnvOffset;
    for (final byte in input.codeUnits) {
      hash = (hash ^ byte) & mask;
      hash = (hash * fnvPrime) & mask;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  /// Generates (or returns a cached) thumbnail file path for [url].
  /// [userAgent] is forwarded as an HTTP header when provided. Returns null when
  /// the source can't be decoded; unexpected infrastructure errors are logged.
  Future<String?> generateThumbnail(String url, {String? userAgent}) async {
    final Directory dir;
    try {
      dir = await _thumbsDir();
    } on FileSystemException catch (e) {
      debugPrint('MetadataService: cannot open thumbnail cache dir: $e');
      return null;
    }

    final outPath = p.join(dir.path, '${_cacheKey(url)}.jpg');
    final existing = File(outPath);
    if (await existing.exists() && await existing.length() > 0) {
      return outPath;
    }

    final String? result;
    try {
      result = await _channel.invokeMethod<String>('generateThumbnail', {
        'url': url,
        'userAgent': userAgent,
        'outPath': outPath,
      });
    } on PlatformException catch (e) {
      debugPrint('MetadataService: native thumbnail error: $e');
      return null;
    } on MissingPluginException catch (e) {
      debugPrint('MetadataService: thumbnail plugin missing: $e');
      return null;
    }

    // A null result is the expected "source can't be decoded" outcome.
    if (result == null) return null;
    final f = File(result);
    if (await f.exists() && await f.length() > 0) return result;
    return null;
  }
}
