import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../models/video_item.dart';
import '../services/clear_key.dart';
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

  const VideoPlayerView({
    super.key,
    required this.item,
    this.onInitialized,
    this.positionSink,
    this.onEdit,
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
        final sniffed =
            await ClearKeyResolver.sniffFormat(resolved.url, headers: headers);
        if (_isStale(gen)) return;
        resolved = resolved.withFormat(sniffed ?? 'hls');
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

      final controller = BetterPlayerController(
        BetterPlayerConfiguration(
          autoPlay: true,
          fit: BoxFit.contain,
          aspectRatio: 16 / 9,
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
          controlsConfiguration: const BetterPlayerControlsConfiguration(
            enablePlayPause: true,
            enableSkips: true, // ±10s, relative (skipForward/skipBack)
            forwardSkipTimeInMilliseconds: 10000,
            backwardSkipTimeInMilliseconds: 10000,
            enableProgressBar: true,
            enableProgressBarDrag: true,
            enableProgressText: true,
            enableFullscreen: true,
            enableMute: true,
            enablePlaybackSpeed: true,
            enableOverflowMenu: true,
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
            WakelockCoordinator.instance.acquire(this);
          case BetterPlayerEventType.progress:
            final position = controller.videoPlayerController?.value.position;
            if (position != null) widget.positionSink?.value = position;
          case BetterPlayerEventType.exception:
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
        controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (e) {
      if (_isStale(gen)) return;
      setState(() => _error = e.toString());
    }
  }

  void _retry() {
    _teardown();
    _setUp();
  }

  bool _isStale(int gen) => !mounted || gen != _generation;

  void _teardown() {
    _generation++;
    _controller?.dispose();
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
