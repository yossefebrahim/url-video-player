import 'package:flutter/material.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';

import '../models/video_item.dart';
import '../services/cast_service.dart';

/// Transport controls shown in the player box while a Cast session is active.
///
/// Fills the role of the local [VideoPlayerView] during casting: title, remote
/// play/pause (driven by [CastService.mediaStatus]), ±10s seek, stop, a LIVE
/// badge and a device-volume slider. Kept compact + scroll-safe so it never
/// overflows the fixed 16:9 stage at large text scales.
class CastMiniController extends StatefulWidget {
  final VideoItem? item;
  final String? deviceName;

  const CastMiniController({super.key, this.item, this.deviceName});

  @override
  State<CastMiniController> createState() => _CastMiniControllerState();
}

class _CastMiniControllerState extends State<CastMiniController> {
  final _cast = CastService.instance;
  double _volume = 0.5;
  bool _volumeTouched = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: StreamBuilder<GoggleCastMediaStatus?>(
        stream: _cast.mediaStatus,
        builder: (context, snapshot) {
          final status = snapshot.data;
          final playing = status?.playerState == CastMediaPlayerState.playing;
          final duration = status?.mediaInformation?.duration;
          final isLive = duration == null || duration <= Duration.zero;
          if (status != null && !_volumeTouched) {
            _volume = status.volume.toDouble().clamp(0.0, 1.0);
          }
          return Center(
            child: SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const ExcludeSemantics(
                        child: Icon(Icons.cast_connected,
                            color: Colors.white70, size: 22),
                      ),
                      if (isLive) ...[
                        const SizedBox(width: 8),
                        const _LiveBadge(),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.item?.title.isNotEmpty == true
                        ? widget.item!.title
                        : 'Casting',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    'On ${widget.deviceName ?? 'your TV'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _iconBtn(Icons.replay_10, 'Rewind 10 seconds',
                          () => _cast.seekBy(const Duration(seconds: -10))),
                      const SizedBox(width: 8),
                      _iconBtn(
                        playing ? Icons.pause_circle : Icons.play_circle,
                        playing ? 'Pause' : 'Play',
                        () => playing ? _cast.pause() : _cast.play(),
                        size: 46,
                      ),
                      const SizedBox(width: 8),
                      _iconBtn(Icons.forward_10, 'Forward 10 seconds',
                          () => _cast.seekBy(const Duration(seconds: 10))),
                      const SizedBox(width: 8),
                      _iconBtn(
                          Icons.stop_circle, 'Stop casting', _cast.disconnect),
                    ],
                  ),
                  Row(
                    children: [
                      const ExcludeSemantics(
                        child: Icon(Icons.volume_down,
                            color: Colors.white54, size: 20),
                      ),
                      Expanded(
                        child: Semantics(
                          label: 'Cast volume',
                          child: Slider(
                            value: _volume,
                            semanticFormatterCallback: (v) =>
                                '${(v * 100).round()}% volume',
                            onChanged: (v) {
                              setState(() {
                                _volume = v;
                                _volumeTouched = true;
                              });
                              _cast.setVolume(v);
                            },
                            onChangeEnd: (_) => _volumeTouched = false,
                          ),
                        ),
                      ),
                      const ExcludeSemantics(
                        child: Icon(Icons.volume_up,
                            color: Colors.white54, size: 20),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _iconBtn(IconData icon, String label, VoidCallback onTap,
      {double size = 34}) {
    return IconButton(
      onPressed: onTap,
      tooltip: label,
      icon: Icon(icon, color: Colors.white, size: size),
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      padding: const EdgeInsets.all(6),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Text(
        'LIVE',
        style: TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
