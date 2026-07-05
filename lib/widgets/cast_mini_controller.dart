import 'package:flutter/material.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';

import '../app_theme.dart';
import '../models/video_item.dart';
import '../services/cast_service.dart';

/// Transport controls shown in the player box while a Cast session is active.
///
/// Fills the role of the local [VideoPlayerView] during casting: title, remote
/// play/pause (driven by [CastService.mediaStatus]), ±10s seek, stop, and a
/// device volume slider.
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: StreamBuilder<GoggleCastMediaStatus?>(
        stream: _cast.mediaStatus,
        builder: (context, snapshot) {
          final status = snapshot.data;
          final playing =
              status?.playerState == CastMediaPlayerState.playing;
          if (status != null && !_volumeTouched) {
            _volume = status.volume.toDouble().clamp(0.0, 1.0);
          }
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cast_connected, color: Colors.white, size: 34),
              const SizedBox(height: 6),
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
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _iconBtn(Icons.replay_10,
                      () => _cast.seekBy(const Duration(seconds: -10))),
                  const SizedBox(width: 8),
                  _iconBtn(
                    playing ? Icons.pause_circle : Icons.play_circle,
                    () => playing ? _cast.pause() : _cast.play(),
                    size: 46,
                  ),
                  const SizedBox(width: 8),
                  _iconBtn(Icons.forward_10,
                      () => _cast.seekBy(const Duration(seconds: 10))),
                  const SizedBox(width: 8),
                  _iconBtn(Icons.stop_circle, _cast.disconnect),
                ],
              ),
              Row(
                children: [
                  const Icon(Icons.volume_down,
                      color: Colors.white54, size: 20),
                  Expanded(
                    child: SliderTheme(
                      data: SliderThemeData(
                        activeTrackColor: AppTheme.primaryRed,
                        thumbColor: AppTheme.primaryRed,
                        inactiveTrackColor: Colors.white24,
                        trackHeight: 2,
                        overlayShape:
                            const RoundSliderOverlayShape(overlayRadius: 12),
                      ),
                      child: Slider(
                        value: _volume,
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
                  const Icon(Icons.volume_up,
                      color: Colors.white54, size: 20),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _iconBtn(IconData icon, VoidCallback onTap, {double size = 34}) {
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon, color: Colors.white, size: size),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
    );
  }
}
