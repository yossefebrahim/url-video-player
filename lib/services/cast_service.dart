import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/video_item.dart';
import 'cast_media_mapper.dart';
import 'cast_proxy_server.dart';
import 'cenc_decryptor.dart';
import 'clear_key.dart';

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

  /// Custom CAF receiver (App ID `7B6F0F4A`) — uses the TV's hardware HEVC
  /// decoder, which the default Styled Media Receiver (`CC1AD845`) can't do.
  /// It also plays the H.264 VOD/DASH the proxy already serves, so it replaces
  /// the default receiver for everything. Unpublished → only launches on Cast
  /// devices registered in the Cast console (the Mi TV, "Ready For Testing").
  static const String defaultReceiverAppId = '7B6F0F4A';
  static const String styledMediaReceiverAppId = 'CC1AD845';

  final ValueNotifier<CastState> state =
      ValueNotifier<CastState>(const CastState(CastPhase.idle));

  /// Bumps whenever the receiver/remote ends the session on its own (i.e. not
  /// through our own [disconnect]). The UI listens and shows a passive
  /// "Cast disconnected" note, without firing on a user-initiated stop.
  final ValueNotifier<int> passiveDisconnects = ValueNotifier<int>(0);

  bool _initialized = false;
  bool _endingByUser = false;
  StreamSubscription<GoogleCastSession?>? _sessionSub;

  /// Live only while casting through the phone (ClearKey-DASH decrypt proxy or
  /// the live-HLS proxy). While it runs the phone must stay awake and on
  /// Wi-Fi, so [_adoptProxy] holds a wakelock for its lifetime.
  CastProxy? _proxy;

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
      final media = await _prepareMedia(item);
      await GoogleCastRemoteMediaClient.instance.loadMedia(
        media,
        autoPlay: true,
        playPosition: start,
        customData: media.customData,
      );
      // The default receiver silently shows its idle splash for streams it
      // can't play (HEVC, or token'd/User-Agent-gated live HLS). Don't claim to
      // be casting until it actually starts — otherwise the user stares at a
      // blank "connected" TV while the app says "casting".
      if (!await _awaitPlaybackStarted()) {
        await _endSessionQuietly();
        _set(CastState(CastPhase.error,
            deviceName: device.friendlyName,
            errorMessage:
                "Your TV's built-in receiver couldn't play this stream. Live "
                'channels that use HEVC or need a custom User-Agent are not '
                'supported yet — still playing on your phone.'));
        return false;
      }
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

  /// Builds the Cast media for [item], proxying through the phone when the
  /// receiver can't fetch or decrypt the stream on its own:
  ///
  ///  * ClearKey **CENC DASH** → [CastProxyServer] decrypts and serves clear
  ///    DASH (the receiver has no ClearKey CDM);
  ///  * **live/UA-gated HLS** (the obfuscated `.json` channels, or any HLS
  ///    with a custom User-Agent) → [HlsCastProxy] fetches with the UA,
  ///    strips AES-128 phone-side, and serves clear TS. Cast can never apply
  ///    a User-Agent itself, so without the proxy these never start.
  ///
  /// Everything else casts its origin URL directly.
  Future<GoogleCastMediaInformation> _prepareMedia(VideoItem item) async {
    await _stopProxy();

    var resolved = ClearKeyResolver.resolve(item.url);
    final ua = item.userAgent;
    final headers = <String, String>{
      if (ua != null && ua.isNotEmpty) 'User-Agent': ua,
    };
    final title = item.title.isEmpty ? 'Video' : item.title;

    final isCencDash = resolved.isEncrypted &&
        resolved.keyBytes != null &&
        (resolved.format == 'dash' ||
            resolved.url.toLowerCase().contains('.mpd'));

    if (isCencDash) {
      final localUrl = await _adoptProxy(CastProxyServer(
        upstreamMpdUrl: resolved.url,
        decryptor: CencDecryptor(resolved.keyBytes!),
        upstreamHeaders: headers,
      ));
      return GoogleCastMediaInformation(
        contentId: localUrl.toString(),
        streamType: CastMediaStreamType.buffered,
        contentType: 'application/dash+xml',
        metadata: GoogleCastGenericMediaMetadata(title: title),
        customData: {'beacon': _beaconUrl(localUrl)},
      );
    }

    // Same container resolution as local playback (opaque `.json` hand-offs).
    final obfuscated = ClearKeyResolver.needsSniff(resolved);
    if (obfuscated) {
      final sniffed =
          await ClearKeyResolver.sniffFormat(resolved.url, headers: headers);
      resolved = resolved.withFormat(sniffed ?? 'hls');
    }

    final needsHlsProxy = !resolved.isEncrypted &&
        resolved.format == 'hls' &&
        (obfuscated || headers.isNotEmpty);
    if (needsHlsProxy) {
      final localUrl = await _adoptProxy(HlsCastProxy(
        upstreamPlaylistUrl: resolved.url,
        upstreamHeaders: headers,
      ));
      return GoogleCastMediaInformation(
        contentId: localUrl.toString(),
        // Live-ness is judged from the ORIGIN url — the proxy URL is opaque.
        streamType: CastMediaMapper.streamTypeFor('hls', resolved.url),
        contentType: 'application/vnd.apple.mpegurl',
        metadata: GoogleCastGenericMediaMetadata(title: title),
        customData: {'beacon': _beaconUrl(localUrl)},
      );
    }

    return CastMediaMapper.mediaInfoFor(item, resolved);
  }

  /// Starts [proxy], records it as the session proxy, and holds a wakelock for
  /// its lifetime: with the screen off, Doze suspends the app's sockets and
  /// the TV would stall mid-stream. Throws if the phone has no LAN address.
  Future<Uri> _adoptProxy(CastProxy proxy) async {
    final localUrl = await proxy.start();
    if (localUrl == null) {
      await proxy.stop();
      throw StateError('No Wi-Fi address available for the cast proxy');
    }
    _proxy = proxy;
    try {
      await WakelockPlus.enable();
    } catch (e) {
      debugPrint('CastService: wakelock enable failed: $e');
    }
    return localUrl;
  }

  Future<void> _stopProxy() async {
    final proxy = _proxy;
    _proxy = null;
    if (proxy == null) return;
    await proxy.stop();
    try {
      await WakelockPlus.disable();
    } catch (e) {
      debugPrint('CastService: wakelock disable failed: $e');
    }
  }

  static String _beaconUrl(Uri localUrl) =>
      localUrl.replace(path: '/beacon', queryParameters: null).toString();

  Future<void> play() => _guard(GoogleCastRemoteMediaClient.instance.play);
  Future<void> pause() => _guard(GoogleCastRemoteMediaClient.instance.pause);

  /// Absolute seek.
  Future<void> seekTo(Duration position) => _guard(() =>
      GoogleCastRemoteMediaClient.instance
          .seek(GoogleCastMediaSeekOption(position: position)));

  /// Relative jump (e.g. ±10s).
  ///
  /// `flutter_chrome_cast` 1.4.6's Android bridge
  /// (`GoogleCastSeekOptionsBuilder.fromMap`) silently ignores the
  /// `relative` flag on [GoogleCastMediaSeekOption] and always issues an
  /// absolute `setPosition`, so `position: delta, relative: true` would jump
  /// to an absolute 0:10 instead of +10s. We therefore compute the absolute
  /// target ourselves from the live [GoogleCastRemoteMediaClient.playerPosition]
  /// and clamp it into the stream's bounds before issuing an absolute seek.
  Future<void> seekBy(Duration delta) => _guard(() async {
        final client = GoogleCastRemoteMediaClient.instance;
        final current = client.playerPosition;
        var target = current + delta;
        if (target < Duration.zero) target = Duration.zero;
        final duration = client.mediaStatus?.mediaInformation?.duration;
        if (duration != null && duration > Duration.zero && target > duration) {
          target = duration;
        }
        await client.seek(GoogleCastMediaSeekOption(position: target));
      });

  Future<void> setVolume(double value) => _guard(() async =>
      GoogleCastSessionManager.instance.setDeviceVolume(value.clamp(0.0, 1.0)));

  /// Ends the session and stops playback on the receiver.
  Future<void> disconnect() async {
    if (!supported) return;
    // Mark this as user-initiated so the session-stream callback doesn't
    // mistake it for a passive drop and fire the "Cast disconnected" note.
    _endingByUser = true;
    await _stopProxy();
    try {
      await GoogleCastSessionManager.instance.endSessionAndStopCasting();
    } catch (e) {
      debugPrint('CastService.disconnect failed: $e');
    }
    _set(const CastState(CastPhase.idle));
    _endingByUser = false;
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

  /// After `loadMedia`, confirms the receiver actually reached **playing**.
  /// Returns false if it errors out or never truly starts within [timeout].
  ///
  /// `playing` is the only trustworthy signal: the default receiver parks a
  /// stream it can't handle (HEVC, or a token'd/User-Agent-gated live HLS) in
  /// `buffering`/`paused`/`idle` while showing its blank splash, so those must
  /// NOT count as success or we'd claim to be casting to a blank TV.
  Future<bool> _awaitPlaybackStarted(
      {Duration timeout = const Duration(seconds: 15)}) async {
    final client = GoogleCastRemoteMediaClient.instance;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final status = client.mediaStatus;
      switch (status?.playerState) {
        case CastMediaPlayerState.playing:
          return true;
        case CastMediaPlayerState.idle
            when status?.idleReason == GoogleCastMediaIdleReason.error:
          return false;
        default:
          break; // unknown / idle / loading / buffering / paused → keep waiting
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return false; // never reached "playing"
  }

  /// Ends the CAF session + proxy WITHOUT emitting a state (the caller sets the
  /// next state). Guards the passive-disconnect note so it doesn't fire here.
  Future<void> _endSessionQuietly() async {
    _endingByUser = true;
    await _stopProxy();
    try {
      await GoogleCastSessionManager.instance.endSessionAndStopCasting();
    } catch (e) {
      debugPrint('CastService._endSessionQuietly failed: $e');
    }
    _endingByUser = false;
  }

  /// Catches sessions that end from the TV/remote so the UI falls back to local.
  ///
  /// Only reacts to a drop of an ESTABLISHED session (connected/casting); during
  /// connecting/error we're mid-handshake and set our own state, so ignoring
  /// those avoids clobbering an error we just set (e.g. an unplayable stream).
  void _onSessionChanged(GoogleCastSession? session) {
    final conn = GoogleCastSessionManager.instance.connectionState;
    final phase = state.value.phase;
    final wasActive =
        phase == CastPhase.connected || phase == CastPhase.castingMedia;
    if (conn == GoogleCastConnectState.disconnected && wasActive) {
      _stopProxy();
      _set(const CastState(CastPhase.idle));
      // Only a genuine passive drop (TV powered off, remote stop, network) —
      // a user-initiated disconnect() sets _endingByUser first.
      if (!_endingByUser) passiveDisconnects.value++;
    }
  }

  void _set(CastState next) => state.value = next;
}
