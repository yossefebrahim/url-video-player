import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';

import '../models/video_item.dart';
import 'cast_media_mapper.dart';

/// Lifecycle of a Cast session as the UI cares about it.
enum CastPhase { idle, discovering, connecting, connected, castingMedia, error }

/// Reactive snapshot the AppBar button and player box listen to.
@immutable
class CastState {
  final CastPhase phase;
  final String? deviceName;
  final String? errorMessage;

  const CastState(this.phase, {this.deviceName, this.errorMessage});

  /// A session exists (connecting, connected, or actively casting media).
  bool get isConnected =>
      phase == CastPhase.connecting ||
      phase == CastPhase.connected ||
      phase == CastPhase.castingMedia;

  /// Media is loaded on the receiver — the local player should stand down.
  bool get isCasting => phase == CastPhase.castingMedia;
}

/// Owns the Google Cast (CAF) session: discovery, connect, load, remote control.
///
/// Android-only wiring today (see [supported]); every platform call is guarded
/// so the app degrades to local playback if Cast is unavailable or errors. The
/// receiver is the default Styled Media Receiver (`CC1AD845`); swapping in a
/// custom receiver id here is the whole of the Phase-2 upgrade.
class CastService {
  CastService._();
  static final CastService instance = CastService._();

  static const String defaultReceiverAppId = 'CC1AD845';

  final ValueNotifier<CastState> state =
      ValueNotifier<CastState>(const CastState(CastPhase.idle));

  bool _initialized = false;
  StreamSubscription<GoogleCastSession?>? _sessionSub;

  /// Cast is only wired for Android in this build.
  bool get supported => Platform.isAndroid;

  /// Live list of discovered devices (empty until [startDiscovery]).
  Stream<List<GoogleCastDevice>> get devices =>
      GoogleCastDiscoveryManager.instance.devicesStream;

  /// Remote media status (player state / volume) for the mini-controller.
  Stream<GoggleCastMediaStatus?> get mediaStatus =>
      GoogleCastRemoteMediaClient.instance.mediaStatusStream;

  /// Idempotent one-time CAF context init. Safe to call repeatedly.
  Future<void> ensureInitialized() async {
    if (_initialized || !supported) return;
    try {
      await GoogleCastContext.instance.setSharedInstanceWithOptions(
        GoogleCastOptionsAndroid(appId: defaultReceiverAppId),
      );
      _initialized = true;
      await _sessionSub?.cancel();
      _sessionSub = GoogleCastSessionManager.instance.currentSessionStream
          .listen(_onSessionChanged);
    } catch (e) {
      debugPrint('CastService.ensureInitialized failed: $e');
    }
  }

  Future<void> startDiscovery() async {
    if (!supported) return;
    await ensureInitialized();
    try {
      await GoogleCastDiscoveryManager.instance.startDiscovery();
      if (!state.value.isConnected) {
        _set(const CastState(CastPhase.discovering));
      }
    } catch (e) {
      debugPrint('CastService.startDiscovery failed: $e');
    }
  }

  Future<void> stopDiscovery() async {
    if (!supported) return;
    try {
      await GoogleCastDiscoveryManager.instance.stopDiscovery();
    } catch (_) {}
    if (state.value.phase == CastPhase.discovering) {
      _set(const CastState(CastPhase.idle));
    }
  }

  /// Connects to [device] and loads [item] on it, starting at [start].
  /// Returns false (and sets an error state) if connect or load fails.
  Future<bool> connectAndCast(
    GoogleCastDevice device,
    VideoItem item, {
    Duration start = Duration.zero,
  }) async {
    if (!supported) return false;
    await ensureInitialized();
    _set(CastState(CastPhase.connecting, deviceName: device.friendlyName));
    try {
      final started =
          await GoogleCastSessionManager.instance.startSessionWithDevice(device);
      if (!started) {
        _set(CastState(CastPhase.error,
            deviceName: device.friendlyName,
            errorMessage: 'Could not connect to ${device.friendlyName}'));
        return false;
      }
      await _awaitConnected();
      final media = await CastMediaMapper.buildMediaInfo(item);
      await GoogleCastRemoteMediaClient.instance.loadMedia(
        media,
        autoPlay: true,
        playPosition: start,
        customData: media.customData,
      );
      _set(CastState(CastPhase.castingMedia, deviceName: device.friendlyName));
      await stopDiscovery();
      return true;
    } catch (e) {
      debugPrint('CastService.connectAndCast failed: $e');
      _set(CastState(CastPhase.error,
          deviceName: device.friendlyName,
          errorMessage: "Couldn't cast this video on your TV"));
      return false;
    }
  }

  Future<void> play() => _guard(GoogleCastRemoteMediaClient.instance.play);
  Future<void> pause() => _guard(GoogleCastRemoteMediaClient.instance.pause);

  /// Absolute seek.
  Future<void> seekTo(Duration position) => _guard(() =>
      GoogleCastRemoteMediaClient.instance
          .seek(GoogleCastMediaSeekOption(position: position)));

  /// Relative jump (e.g. ±10s).
  Future<void> seekBy(Duration delta) => _guard(() =>
      GoogleCastRemoteMediaClient.instance.seek(
          GoogleCastMediaSeekOption(position: delta, relative: true)));

  Future<void> setVolume(double value) => _guard(() async =>
      GoogleCastSessionManager.instance.setDeviceVolume(value.clamp(0.0, 1.0)));

  /// Ends the session and stops playback on the receiver.
  Future<void> disconnect() async {
    if (!supported) return;
    try {
      await GoogleCastSessionManager.instance.endSessionAndStopCasting();
    } catch (e) {
      debugPrint('CastService.disconnect failed: $e');
    }
    _set(const CastState(CastPhase.idle));
  }

  // ── internals ────────────────────────────────────────────────────────────

  Future<void> _guard(Future<void> Function() action) async {
    if (!supported) return;
    try {
      await action();
    } catch (e) {
      debugPrint('CastService remote action failed: $e');
    }
  }

  Future<void> _awaitConnected(
      {Duration timeout = const Duration(seconds: 15)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (GoogleCastSessionManager.instance.connectionState ==
          GoogleCastConnectState.connected) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw TimeoutException('Cast connection timed out');
  }

  /// Catches sessions that end from the TV/remote so the UI falls back to local.
  void _onSessionChanged(GoogleCastSession? session) {
    final conn = GoogleCastSessionManager.instance.connectionState;
    if (conn == GoogleCastConnectState.disconnected &&
        state.value.phase != CastPhase.idle &&
        state.value.phase != CastPhase.discovering) {
      _set(const CastState(CastPhase.idle));
    }
  }

  void _set(CastState next) => state.value = next;
}
