import 'dart:async';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_theme.dart';
import '../models/video_item.dart';
import '../widgets/video_player_view.dart';

/// Fullscreen, remote-controlled player for Android TV / Google TV.
///
/// Hosts [VideoPlayerView] (reusing all of its ClearKey / LiveHlsProxy / DRM /
/// User-Agent setup) inside a black full-bleed [Scaffold] and drives it from
/// the TV remote's D-pad:
///
///  * RIGHT / media-FF   → seek +10s
///  * LEFT  / media-RW    → seek −10s
///  * OK / CENTER / media-play-pause → toggle play/pause
///  * UP / DOWN           → open the controls menu (quality / speed / fit)
///  * BACK                → close the menu, or exit the player
///
/// We own the fullscreen surface, so the plugin's built-in fullscreen +
/// (tap-only, non-focusable) overflow/quality menu are disabled in `tvMode`;
/// the quality picker here is built from the controller's track list and is
/// D-pad focusable.
class TvPlayerScreen extends StatefulWidget {
  final VideoItem item;

  /// Forwarded to [VideoPlayerView.onInitialized] so the host can persist
  /// duration/resolution just like the inline player does.
  final void Function(Duration duration, Size size)? onInitialized;

  const TvPlayerScreen({super.key, required this.item, this.onInitialized});

  @override
  State<TvPlayerScreen> createState() => _TvPlayerScreenState();
}

class _TvPlayerScreenState extends State<TvPlayerScreen> {
  BetterPlayerController? _controller;
  final FocusNode _rootFocus = FocusNode(debugLabel: 'tv-player-root');
  // A real FocusScope for the controls menu: its own scope lets the first
  // button's autofocus win (the route scope is already held by _rootFocus) and
  // keeps directional traversal contained inside the menu.
  final FocusScopeNode _menuScope = FocusScopeNode(debugLabel: 'tv-menu');

  /// Lightweight bottom HUD (play state + position); does NOT take focus, so
  /// the D-pad keeps seeking while it's up. Auto-hides.
  bool _infoVisible = false;
  Timer? _infoTimer;

  /// The focusable controls menu (quality / speed / fit). Takes focus while open.
  bool _menuOpen = false;

  bool _coverFit = false; // false = contain (letterbox), true = cover (zoom)

  // Held-key seek: coalesce rapid repeats into one seekTo.
  Duration _pendingSeek = Duration.zero;
  Timer? _seekTimer;

  // Reconnect state. VideoPlayerView is keyed by (url # attempt); bumping the
  // attempt remounts it → a fresh setup, i.e. a reconnect. Live streams drop
  // often, so the screen auto-reconnects a few times before asking the user.
  int _attempt = 0;
  bool _hasError = false;
  int _autoRetries = 0;
  Timer? _retryTimer;

  static const Duration _seekStep = Duration(seconds: 10);
  static const Duration _infoTimeout = Duration(seconds: 3);
  static const int _maxAutoRetries = 5;
  static const Duration _retryDelay = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    // True fullscreen: hide status/nav bars (mostly a phone concern; harmless
    // on a TV, which is already full-bleed).
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    _infoTimer?.cancel();
    _seekTimer?.cancel();
    _retryTimer?.cancel();
    _controller?.removeEventsListener(_onPlayerEvent);
    _rootFocus.dispose();
    _menuScope.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _onControllerReady(BetterPlayerController controller) {
    if (identical(_controller, controller)) return;
    // A reconnect builds a fresh controller; drop the old one's listener so
    // they don't accumulate (the old controller is force-disposed on remount).
    _controller?.removeEventsListener(_onPlayerEvent);
    _controller = controller;
    // Keep the overlay's position/state text live while it's showing.
    controller.addEventsListener(_onPlayerEvent);
  }

  /// Reported by [VideoPlayerView] on setup failure / mid-play exception (and
  /// cleared on (re)load). Auto-reconnects live streams a few times, then falls
  /// back to a remote-reachable manual retry (see [_errorOverlay]).
  void _onErrorChanged(bool hasError) {
    if (!mounted) return;
    if (!hasError) {
      _retryTimer?.cancel();
      if (_hasError || _autoRetries != 0) {
        setState(() {
          _hasError = false;
          _autoRetries = 0; // a clean (re)load resets the budget
        });
      }
      return;
    }
    if (_hasError) return; // already handling this failure
    setState(() {
      _hasError = true;
      _menuOpen = false; // the error overlay owns the screen now
      _infoVisible = false;
    });
    _rootFocus.requestFocus(); // reclaim the D-pad from the (now-hidden) menu
    if (_autoRetries < _maxAutoRetries) {
      _retryTimer?.cancel();
      _retryTimer = Timer(_retryDelay, () {
        if (!mounted) return;
        _autoRetries++;
        _reconnect();
      });
    }
  }

  /// Remounts the player (fresh setup / reconnect) by bumping the keyed attempt.
  void _reconnect() {
    _retryTimer?.cancel();
    _controller?.removeEventsListener(_onPlayerEvent);
    setState(() {
      _hasError = false;
      // The old controller is about to be force-disposed by the remounting
      // VideoPlayerView; drop our reference so a stray key press can't touch it.
      _controller = null;
      _attempt++;
    });
  }

  /// User-driven retry (OK on the error screen): also resets the auto budget.
  void _manualRetry() {
    _autoRetries = 0;
    _reconnect();
  }

  void _onPlayerEvent(BetterPlayerEvent event) {
    if (!mounted) return;
    switch (event.betterPlayerEventType) {
      case BetterPlayerEventType.progress:
      case BetterPlayerEventType.changedTrack:
        if (_infoVisible || _menuOpen) setState(() {});
        break;
      default:
        break;
    }
  }

  // ── remote input ───────────────────────────────────────────────────────────

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    // While the menu is open it owns the D-pad: let focus traversal move
    // between the focusable buttons and let them activate. BACK is handled by
    // the PopScope below.
    if (_menuOpen) return KeyEventResult.ignored;

    // On the error screen, OK retries; everything else (incl. BACK → exit)
    // falls through.
    if (_hasError) {
      if (_isSelectKey(event.logicalKey)) {
        _manualRetry();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.mediaFastForward ||
        key == LogicalKeyboardKey.mediaTrackNext) {
      _seekBy(_seekStep);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.mediaRewind ||
        key == LogicalKeyboardKey.mediaTrackPrevious) {
      _seekBy(-_seekStep);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.gameButtonA ||
        key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      _togglePlayPause();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      _openMenu();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  static bool _isSelectKey(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.select ||
      k == LogicalKeyboardKey.enter ||
      k == LogicalKeyboardKey.space ||
      k == LogicalKeyboardKey.gameButtonA;

  void _seekBy(Duration delta) {
    if (_controller == null) return;
    _pendingSeek += delta;
    _seekTimer?.cancel();
    _seekTimer = Timer(const Duration(milliseconds: 220), _flushSeek);
    _flashInfo();
  }

  void _flushSeek() {
    final c = _controller;
    final delta = _pendingSeek;
    _pendingSeek = Duration.zero;
    if (c == null) return;
    final value = c.videoPlayerController?.value;
    final pos = value?.position ?? Duration.zero;
    c.seekTo(clampSeekTarget(pos, value?.duration, delta));
  }

  void _togglePlayPause() {
    final c = _controller;
    if (c == null) return;
    (c.isPlaying() ?? false) ? c.pause() : c.play();
    _flashInfo();
    setState(() {});
  }

  void _flashInfo() {
    if (!_infoVisible) setState(() => _infoVisible = true);
    _infoTimer?.cancel();
    _infoTimer = Timer(_infoTimeout, () {
      if (mounted && !_menuOpen) setState(() => _infoVisible = false);
    });
  }

  void _openMenu() {
    _infoTimer?.cancel();
    setState(() {
      _menuOpen = true;
      _infoVisible = false;
    });
    // Explicitly move focus into the menu scope — autofocus alone is discarded
    // because the route scope's focusedChild is still the root Focus.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _menuOpen) _menuScope.requestFocus();
    });
  }

  void _closeMenu() {
    setState(() => _menuOpen = false);
    _rootFocus.requestFocus(); // hand the D-pad back to the player
  }

  void _toggleFit() {
    final c = _controller;
    if (c == null) return;
    _coverFit = !_coverFit;
    c.setOverriddenFit(_coverFit ? BoxFit.cover : BoxFit.contain);
    setState(() {});
  }

  // ── build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Match the box to the real surface so contain letterboxes and cover fills
    // correctly on any panel (a null aspectRatio makes the plugin fall back to a
    // hardcoded 16:9 box that mis-fills non-16:9 / PiP / multi-window surfaces).
    final screenAspect = MediaQuery.of(context).size.aspectRatio;
    return PopScope(
      // Never let BACK reveal the (TV-hidden) home screen. Menu open → close it;
      // otherwise exit the app back to Ostora / the launcher.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_menuOpen) {
          _closeMenu();
        } else {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _rootFocus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: VideoPlayerView(
                  // The attempt counter makes a reconnect remount the player.
                  key: ValueKey('${widget.item.url}#$_attempt'),
                  item: widget.item,
                  tvMode: true,
                  screenAspectRatio: screenAspect,
                  onControllerReady: _onControllerReady,
                  onInitialized: widget.onInitialized,
                  onErrorChanged: _onErrorChanged,
                ),
              ),
              if (_hasError)
                _ErrorOverlay(
                  item: widget.item,
                  reconnecting: _autoRetries < _maxAutoRetries,
                  attempt: _autoRetries,
                )
              else if (_menuOpen)
                FocusScope(
                  node: _menuScope,
                  child: _ControlsMenu(
                    controller: _controller,
                    item: widget.item,
                    coverFit: _coverFit,
                    onTogglePlayPause: _togglePlayPause,
                    onSeek: _seekBy,
                    onToggleFit: _toggleFit,
                    onClose: _closeMenu,
                  ),
                )
              else if (_infoVisible)
                _InfoBar(controller: _controller, item: widget.item),
            ],
          ),
        ),
      ),
    );
  }
}

/// Non-focusable bottom HUD shown briefly on seek / play-pause. The D-pad still
/// belongs to the player while this is up.
class _InfoBar extends StatelessWidget {
  final BetterPlayerController? controller;
  final VideoItem item;
  const _InfoBar({required this.controller, required this.item});

  @override
  Widget build(BuildContext context) {
    final playing = controller?.isPlaying() ?? false;
    return _BottomScrim(
      child: Row(
        children: [
          Icon(playing ? Icons.play_arrow_rounded : Icons.pause_rounded,
              color: Colors.white, size: 30),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              item.title.isEmpty ? 'Video' : item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
          const SizedBox(width: 12),
          Text(_positionLabel(controller),
              style: const TextStyle(color: Colors.white70, fontSize: 14)),
          const SizedBox(width: 16),
          const Text('▲  Options',
              style: TextStyle(color: Colors.white54, fontSize: 13)),
        ],
      ),
    );
  }
}

/// Full-bleed error / reconnect panel. Not focusable — the root Focus turns OK
/// into a manual retry (see `_onKey`), and auto-reconnect runs on a timer.
class _ErrorOverlay extends StatelessWidget {
  final VideoItem item;
  final bool reconnecting;
  final int attempt;
  const _ErrorOverlay({
    required this.item,
    required this.reconnecting,
    required this.attempt,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(reconnecting ? Icons.wifi_tethering_rounded : Icons.error_outline,
              color: Colors.white54, size: 64),
          const SizedBox(height: 20),
          Text(
            reconnecting
                ? 'Reconnecting…${attempt > 0 ? ' ($attempt)' : ''}'
                : "Couldn't play this channel",
            style: const TextStyle(
                color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          Text(
            reconnecting ? item.title : 'Press OK to try again',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white54, fontSize: 15),
          ),
          if (reconnecting) ...[
            const SizedBox(height: 24),
            const SizedBox(
              height: 30,
              width: 30,
              child: CircularProgressIndicator(
                  strokeWidth: 3, color: AppTheme.primaryRed),
            ),
          ],
        ],
      ),
    );
  }
}

/// The focusable controls menu: play/pause, ±10s, quality, speed, fit.
class _ControlsMenu extends StatelessWidget {
  final BetterPlayerController? controller;
  final VideoItem item;
  final bool coverFit;
  final VoidCallback onTogglePlayPause;
  final void Function(Duration) onSeek;
  final VoidCallback onToggleFit;
  final VoidCallback onClose;

  const _ControlsMenu({
    required this.controller,
    required this.item,
    required this.coverFit,
    required this.onTogglePlayPause,
    required this.onSeek,
    required this.onToggleFit,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final playing = c?.isPlaying() ?? false;
    final tracks = c?.betterPlayerAsmsTracks ?? const <BetterPlayerAsmsTrack>[];
    final current = c?.betterPlayerAsmsTrack;

    return _BottomScrim(
      tall: true,
      child: FocusTraversalGroup(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.title.isEmpty ? 'Video' : item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                Text(_positionLabel(c),
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 14)),
              ],
            ),
            const SizedBox(height: 14),
            // Transport row.
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _TvButton(
                  autofocus: true,
                  icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  label: playing ? 'Pause' : 'Play',
                  onPressed: onTogglePlayPause,
                ),
                _TvButton(
                  icon: Icons.replay_10_rounded,
                  label: '-10s',
                  onPressed: () => onSeek(const Duration(seconds: -10)),
                ),
                _TvButton(
                  icon: Icons.forward_10_rounded,
                  label: '+10s',
                  onPressed: () => onSeek(const Duration(seconds: 10)),
                ),
                _TvButton(
                  icon: coverFit
                      ? Icons.fit_screen_rounded
                      : Icons.aspect_ratio_rounded,
                  label: coverFit ? 'Fit' : 'Fill',
                  onPressed: onToggleFit,
                ),
              ],
            ),
            if (tracks.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text('Quality',
                  style: TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _TvChip(
                    label: 'Auto',
                    selected: current == null || (current.height ?? 0) == 0,
                    onPressed: () {
                      c?.setTrack(BetterPlayerAsmsTrack.defaultTrack());
                      onClose();
                    },
                  ),
                  for (final t in sortedQualityTracks(tracks))
                    _TvChip(
                      label: qualityLabel(t),
                      selected: current != null && current == t,
                      onPressed: () {
                        c?.setTrack(t);
                        onClose();
                      },
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            const Text('Speed',
                style: TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              children: [
                for (final s in const [0.5, 1.0, 1.25, 1.5, 2.0])
                  _TvChip(
                    label: s == 1.0 ? '1x' : '${s}x',
                    selected: false,
                    onPressed: () => c?.setSpeed(s),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Clamps a relative seek to `[0, duration]`. A null / non-positive [duration]
/// (a live stream, or a not-yet-initialized player) has no upper bound.
@visibleForTesting
Duration clampSeekTarget(Duration position, Duration? duration, Duration delta) {
  var target = position + delta;
  if (target < Duration.zero) target = Duration.zero;
  if (duration != null && duration > Duration.zero && target > duration) {
    target = duration;
  }
  return target;
}

/// Deduped, highest-first list of playable tracks (drops the plugin's empty
/// "auto" placeholder, which we surface as a separate chip).
@visibleForTesting
List<BetterPlayerAsmsTrack> sortedQualityTracks(
    List<BetterPlayerAsmsTrack> tracks) {
  final real = tracks.where((t) => (t.height ?? 0) > 0).toList();
  final seen = <int>{};
  final deduped = <BetterPlayerAsmsTrack>[];
  for (final t in real) {
    if (seen.add(t.height!)) deduped.add(t);
  }
  deduped.sort((a, b) => (b.height ?? 0).compareTo(a.height ?? 0));
  return deduped;
}

@visibleForTesting
String qualityLabel(BetterPlayerAsmsTrack t) {
  final h = t.height ?? 0;
  return h > 0 ? '${h}p' : 'Auto';
}

String _positionLabel(BetterPlayerController? c) {
  final value = c?.videoPlayerController?.value;
  final pos = value?.position ?? Duration.zero;
  final dur = value?.duration;
  if (dur == null || dur.inMilliseconds <= 0) {
    return formatMediaTime(pos); // live / unknown
  }
  return '${formatMediaTime(pos)} / ${formatMediaTime(dur)}';
}

@visibleForTesting
String formatMediaTime(Duration d) {
  final neg = d.isNegative;
  final a = d.abs();
  final h = a.inHours;
  final m = (a.inMinutes % 60).toString().padLeft(2, '0');
  final s = (a.inSeconds % 60).toString().padLeft(2, '0');
  final base = h > 0 ? '$h:$m:$s' : '$m:$s';
  return neg ? '-$base' : base;
}

/// Bottom gradient scrim that holds the overlays.
class _BottomScrim extends StatelessWidget {
  final Widget child;
  final bool tall;
  const _BottomScrim({required this.child, this.tall = false});

  @override
  Widget build(BuildContext context) {
    // TVs overscan ~5% of the frame and usually report zero SafeArea insets, so
    // keep the controls inside a manual title-safe margin instead.
    final size = MediaQuery.of(context).size;
    final hMargin = size.width * 0.05;
    final vMargin = size.height * 0.05;
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.fromLTRB(
            hMargin, tall ? 28 : 18, hMargin, vMargin + (tall ? 12 : 8)),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: child,
      ),
    );
  }
}

/// A D-pad-focusable button: highlights on focus and activates on OK/center,
/// enter, space or gamepad-A. (The plugin's own controls aren't focusable, so
/// we can't rely on them for remote navigation.)
class _TvButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool autofocus;
  const _TvButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.autofocus = false,
  });

  @override
  State<_TvButton> createState() => _TvButtonState();
}

class _TvButtonState extends State<_TvButton> {
  bool _focused = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // Edge-triggered: one activation per physical press. (Held-key auto-repeat
    // must not flip play/pause many times — that's the seek path's job.)
    if (event is KeyDownEvent) {
      final k = event.logicalKey;
      if (k == LogicalKeyboardKey.select ||
          k == LogicalKeyboardKey.enter ||
          k == LogicalKeyboardKey.space ||
          k == LogicalKeyboardKey.gameButtonA) {
        widget.onPressed();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: widget.autofocus,
      onKeyEvent: _onKey,
      onFocusChange: (f) => setState(() => _focused = f),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: _focused ? AppTheme.primaryRed : Colors.white24,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _focused ? Colors.white : Colors.transparent,
            width: 2,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(widget.icon, color: Colors.white, size: 22),
            const SizedBox(width: 8),
            Text(widget.label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

/// A compact D-pad-focusable chip for quality / speed options.
class _TvChip extends StatefulWidget {
  final String label;
  final bool selected;
  final VoidCallback onPressed;
  const _TvChip({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  @override
  State<_TvChip> createState() => _TvChipState();
}

class _TvChipState extends State<_TvChip> {
  bool _focused = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // Edge-triggered: one activation per physical press. (Held-key auto-repeat
    // must not flip play/pause many times — that's the seek path's job.)
    if (event is KeyDownEvent) {
      final k = event.logicalKey;
      if (k == LogicalKeyboardKey.select ||
          k == LogicalKeyboardKey.enter ||
          k == LogicalKeyboardKey.space ||
          k == LogicalKeyboardKey.gameButtonA) {
        widget.onPressed();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    return Focus(
      onKeyEvent: _onKey,
      onFocusChange: (f) => setState(() => _focused = f),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: _focused
              ? AppTheme.primaryRed
              : (selected ? Colors.white30 : Colors.white12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _focused
                ? Colors.white
                : (selected ? Colors.white70 : Colors.transparent),
            width: 2,
          ),
        ),
        child: Text(
          widget.label,
          style: TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
