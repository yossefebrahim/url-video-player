import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models/video_item.dart';
import '../services/clear_key.dart';
import '../services/live_hls_proxy.dart';
import '../services/wakelock_coordinator.dart';

/// Inline native video player (better_player_plus / ExoPlayer) for a [VideoItem].
///
/// Supports plain MP4/HLS/DASH plus **ClearKey-encrypted DASH** (the
/// `…/index.mpd###k:kid` scheme used by t4w hand-offs) via [ClearKeyResolver].
/// Reports duration & resolution once the stream initializes.
class VideoPlayerView extends StatefulWidget {
  final VideoItem item;
  final void Function(Duration duration, Size size)? onInitialized;

  /// Kept updated with the current playback position so a Cast hand-off can
  /// start the TV where the phone left off.
  final ValueNotifier<Duration>? positionSink;

  /// Opens the "Add URL" sheet pre-filled with this item (shown as an
  /// "Edit URL" affordance on the error state).
  final VoidCallback? onEdit;

  /// Called with the player controller once it's ready (and again after a
  /// retry recreates it). Lets a host screen — e.g. the fullscreen TV player —
  /// drive play/pause/seek/track selection from the remote without duplicating
  /// this widget's controller setup.
  final void Function(BetterPlayerController controller)? onControllerReady;

  /// TV mode: the host provides its own fullscreen surface and D-pad controls,
  /// so the built-in touch controls (fullscreen button + tap-only overflow /
  /// quality menu, and a competing fullscreen route) are suppressed.
  final bool tvMode;

  /// In [tvMode], the aspect ratio of the fullscreen surface the player fills.
  /// Passed so the video box matches the real screen (contain letterboxes,
  /// cover fills) — a null ratio makes better_player fall back to a hardcoded
  /// 16:9 box that mis-fills non-16:9 / PiP / multi-window surfaces.
  final double? screenAspectRatio;

  /// Called when the error state changes (setup failure or a mid-playback
  /// `exception`, and cleared on (re)load / `initialized`). Lets the TV host
  /// show a remote-reachable retry and auto-reconnect live streams, since the
  /// built-in touch error box isn't D-pad focusable.
  final void Function(bool hasError)? onErrorChanged;

  const VideoPlayerView({
    super.key,
    required this.item,
    this.onInitialized,
    this.positionSink,
    this.onEdit,
    this.onControllerReady,
    this.tvMode = false,
    this.screenAspectRatio,
    this.onErrorChanged,
  });

  @override
  State<VideoPlayerView> createState() => _VideoPlayerViewState();
}

class _VideoPlayerViewState extends State<VideoPlayerView> {
  BetterPlayerController? _controller;
  String? _error;

  // Bumped on each teardown/setup so a stale async setup bails instead of
  // clobbering a fresher controller.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _setUp();
  }

  @override
  void didUpdateWidget(covariant VideoPlayerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A URL change replaces the whole State (keyed by item.url upstream), so
    // only a same-URL user-agent change reaches here.
    if (oldWidget.item.userAgent != widget.item.userAgent) {
      _teardown();
      _setUp();
    }
  }

  Future<void> _setUp() async {
    final gen = ++_generation;
    setState(() => _error = null);
    widget.onErrorChanged?.call(false);

    try {
      var resolved = ClearKeyResolver.resolve(widget.item.url);
      final ua = widget.item.userAgent;
      final headers = <String, String>{
        if (ua != null && ua.isNotEmpty) 'User-Agent': ua,
      };

      // Live channels are handed off with obfuscated extensions (e.g.
      // `…/54_42.json`, a real HLS playlist). Without a format hint ExoPlayer
      // infers "progressive" from `.json` and fails with a Source error, so
      // probe the bytes and force the right container. Fall back to HLS when the
      // probe is inconclusive — opaque hand-offs in this ecosystem are HLS.
      if (ClearKeyResolver.needsSniff(resolved)) {
        final probed = await ClearKeyResolver.probe(resolved.url, headers: headers);
        if (_isStale(gen)) return;
        final format = probed.format ?? 'hls';
        if (format == 'hls' && probed.hasInlineDataKey) {
          // These beIN/nazika channels lock segments with an inline `data:` key
          // ExoPlayer can't fetch. Route through the local proxy, which unwraps
          // the key and serves it back over http so ExoPlayer plays natively.
          final proxied =
              await LiveHlsProxy.instance.wrap(resolved.url, userAgent: ua);
          if (_isStale(gen)) return;
          resolved = ResolvedStream(proxied, format: 'hls');
        } else {
          resolved = resolved.withFormat(format);
        }
      }

      final dataSource = BetterPlayerDataSource(
        BetterPlayerDataSourceType.network,
        resolved.url,
        headers: headers,
        videoFormat: switch (resolved.format) {
          'dash' => BetterPlayerVideoFormat.dash,
          'hls' => BetterPlayerVideoFormat.hls,
          _ => null,
        },
        drmConfiguration: resolved.clearKeyJson != null
            ? BetterPlayerDrmConfiguration(
                drmType: BetterPlayerDrmType.clearKey,
                clearKey: resolved.clearKeyJson,
              )
            : null,
      );

      final tv = widget.tvMode;
      final controller = BetterPlayerController(
        BetterPlayerConfiguration(
          autoPlay: true,
          fit: BoxFit.contain,
          // TV: size the box to the real screen so contain/cover fill correctly
          // (falling back to 16:9 only if the host didn't supply a ratio).
          // Inline (phone) keeps the fixed 16:9 box.
          aspectRatio: tv ? (widget.screenAspectRatio ?? 16 / 9) : 16 / 9,
          // Rotating the phone in fullscreen follows the video; the inline
          // scaffold stays portrait (we do NOT app-lock orientation).
          autoDetectFullscreenDeviceOrientation: true,
          handleLifecycle: true,
          autoDispose: false,
          allowedScreenSleep: false,
          errorBuilder: (context, msg) => _ErrorBox(
            message: msg ?? 'Playback error',
            onRetry: _retry,
            onEdit: widget.onEdit,
          ),
          controlsConfiguration: BetterPlayerControlsConfiguration(
            enablePlayPause: true,
            enableSkips: true, // ±10s, relative (skipForward/skipBack)
            forwardSkipTimeInMilliseconds: 10000,
            backwardSkipTimeInMilliseconds: 10000,
            enableProgressBar: true,
            enableProgressBarDrag: true,
            enableProgressText: true,
            // TV: we own the fullscreen surface + a D-pad-focusable quality
            // menu; the plugin's fullscreen route and tap-only overflow menu
            // would fight us, so they're off.
            enableFullscreen: !tv,
            enableMute: true,
            enablePlaybackSpeed: !tv,
            enableOverflowMenu: !tv,
            enableQualities: !tv,
            showControlsOnInitialize: !tv,
            enableRetry: true,
            enablePip: false, // not wired in the manifest
            enableSubtitles: false,
            controlBarColor: Colors.black54,
            iconsColor: Colors.white,
            progressBarPlayedColor: AppTheme.primaryRed,
            progressBarHandleColor: AppTheme.primaryRed,
            progressBarBufferedColor: Colors.white38,
            loadingColor: AppTheme.primaryRed,
          ),
        ),
        betterPlayerDataSource: dataSource,
      );

      controller.addEventsListener((event) {
        if (_isStale(gen)) return;
        switch (event.betterPlayerEventType) {
          case BetterPlayerEventType.initialized:
            final vpc = controller.videoPlayerController;
            final value = vpc?.value;
            if (value != null) {
              widget.onInitialized?.call(
                value.duration ?? Duration.zero,
                value.size ?? Size.zero,
              );
            }
            widget.onErrorChanged?.call(false);
            WakelockCoordinator.instance.acquire(this);
          case BetterPlayerEventType.progress:
            final position = controller.videoPlayerController?.value.position;
            if (position != null) widget.positionSink?.value = position;
          case BetterPlayerEventType.exception:
            // A mid-playback failure (common on these live streams: token
            // expiry, dropped segment). Tell the TV host so it can reconnect.
            widget.onErrorChanged?.call(true);
            WakelockCoordinator.instance.release(this);
          case BetterPlayerEventType.finished:
            // Playback stopped after initializing (stream died mid-play, or
            // ended). better_player renders its own error/end UI inside this
            // subtree without tearing down our State, so release the wakelock
            // here or it stays held on a stopped video, draining the battery.
            WakelockCoordinator.instance.release(this);
          default:
            break;
        }
      });

      if (_isStale(gen)) {
        controller.dispose(forceDispose: true);
        return;
      }
      setState(() => _controller = controller);
      // Hand the ready controller to a host (TV screen) so it can drive the
      // remote. Fired after the stale re-check so a stale controller is never
      // exposed; re-fires on retry (a fresh controller is built each time).
      widget.onControllerReady?.call(controller);
    } catch (e) {
      if (_isStale(gen)) return;
      setState(() => _error = e.toString());
      widget.onErrorChanged?.call(true);
    }
  }

  void _retry() {
    _teardown();
    _setUp();
  }

  bool _isStale(int gen) => !mounted || gen != _generation;

  void _teardown() {
    _generation++;
    // forceDispose: the controller is built with autoDispose:false, so a plain
    // dispose() is a no-op and would leave the native ExoPlayer decoding (audio
    // continuing after the view is gone). Force it to actually release.
    _controller?.dispose(forceDispose: true);
    _controller = null;
    WakelockCoordinator.instance.release(this);
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _ErrorBox(message: _error!, onRetry: _retry, onEdit: widget.onEdit);
    }
    final controller = _controller;
    if (controller == null) {
      return _LoadingBox(title: widget.item.title);
    }
    return BetterPlayer(controller: controller);
  }
}

/// Branded pre-controller loading state (before the player itself renders).
class _LoadingBox extends StatelessWidget {
  final String title;
  const _LoadingBox({required this.title});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            height: 34,
            width: 34,
            child: CircularProgressIndicator(
                strokeWidth: 3, color: AppTheme.primaryRed),
          ),
          const SizedBox(height: 12),
          Text(
            title.isEmpty ? 'Loading…' : 'Loading “$title”…',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  final VoidCallback? onEdit;
  const _ErrorBox({required this.message, required this.onRetry, this.onEdit});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.white70, size: 40),
            const SizedBox(height: 8),
            const Text(
              'Could not play this video',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, color: Colors.white),
                  label: const Text('Retry',
                      style: TextStyle(color: Colors.white)),
                ),
                if (onEdit != null) ...[
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined, color: Colors.white70),
                    label: const Text('Edit URL',
                        style: TextStyle(color: Colors.white70)),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
