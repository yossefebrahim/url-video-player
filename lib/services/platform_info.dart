import 'dart:io';

import 'package:flutter/services.dart';

/// Whether the app is running on an Android TV / Google TV device.
///
/// Phone and TV share one APK. On a TV, native playback opens a fullscreen,
/// D-pad-driven player (`TvPlayerScreen`); on a phone it stays inline. The
/// verdict comes from the native side (`UiModeManager` / the leanback system
/// feature) over the existing `info.t4w.vp/deeplink` MethodChannel, and never
/// changes at runtime, so it's cached after the first call.
class PlatformInfo {
  PlatformInfo._();

  static const MethodChannel _channel = MethodChannel('info.t4w.vp/deeplink');
  static bool? _isTv;

  /// The cached verdict, or null if [isTv] hasn't resolved yet. Lets
  /// synchronous call sites (e.g. `CastService.supported`) gate on device type
  /// without re-hitting the channel or awaiting. Any cast entry point only runs
  /// from the phone home UI, which itself only renders after [isTv] has
  /// resolved to false — so this is never null at those call sites.
  static bool? get isTvOrNull => _isTv;

  /// True on Android TV / Google TV; false on phones and on any platform or
  /// error where the native probe is unavailable (so the app degrades to the
  /// existing inline player rather than breaking).
  static Future<bool> isTv() async {
    final cached = _isTv;
    if (cached != null) return cached;
    if (!Platform.isAndroid) return _isTv = false;
    try {
      return _isTv = (await _channel.invokeMethod<bool>('isTv')) ?? false;
    } catch (_) {
      // PlatformException / MissingPluginException → assume phone.
      return _isTv = false;
    }
  }
}
