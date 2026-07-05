import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/video_item.dart';
import 'link_parser.dart';

/// Bridges the native intent handling in `MainActivity.kt` to Dart and turns
/// raw payloads into [ParsedLink]s.
class DeepLinkService {
  DeepLinkService._();
  static final DeepLinkService instance = DeepLinkService._();

  static const MethodChannel _method = MethodChannel('info.t4w.vp/deeplink');
  static const EventChannel _events =
      EventChannel('info.t4w.vp/deeplink/events');

  /// The link (if any) that cold-started the app. Consumed once natively.
  ///
  /// Returns null both when there is genuinely no launch link and when the
  /// payload cannot be parsed; a broken channel is logged (in debug) rather
  /// than silently swallowed, so infrastructure failures stay observable.
  Future<ParsedLink?> getInitialLink() async {
    Object? rawPayload;
    try {
      rawPayload = await _method.invokeMethod('getInitialLink');
    } on PlatformException catch (e, s) {
      debugPrint('DeepLinkService.getInitialLink channel error: $e');
      debugPrintStack(stackTrace: s);
      return null;
    } on MissingPluginException catch (e) {
      debugPrint('DeepLinkService.getInitialLink missing plugin: $e');
      return null;
    }
    if (rawPayload is! Map) return null;
    return LinkParser.parsePayload(rawPayload);
  }

  /// Links that arrive while the app is already running (onNewIntent).
  ///
  /// Native error events are logged and dropped (matching getInitialLink's
  /// swallow-and-log policy) so the stream never terminates on a transient
  /// platform error.
  Stream<ParsedLink> get linkStream => _events
      .receiveBroadcastStream()
      .handleError((Object e) => debugPrint('DeepLinkService stream error: $e'))
      .where((e) => e is Map)
      .map((e) => LinkParser.parsePayload(e as Map))
      .where((e) => e != null)
      .cast<ParsedLink>();
}
