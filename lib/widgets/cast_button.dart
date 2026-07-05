import 'package:flutter/material.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';

import '../app_theme.dart';
import '../models/video_item.dart';
import '../services/cast_media_mapper.dart';
import '../services/cast_service.dart';

/// AppBar action that shows Cast status and opens the device picker.
///
/// Hidden on unsupported platforms. Reflects the live [CastState]: grey `cast`
/// icon when idle, filled `cast_connected` when a session is active.
class CastButton extends StatelessWidget {
  final VideoItem? current;

  /// Current local playback position, read when a cast hand-off starts so the
  /// TV resumes where the phone left off.
  final ValueGetter<Duration> localPosition;

  const CastButton({
    super.key,
    required this.current,
    required this.localPosition,
  });

  @override
  Widget build(BuildContext context) {
    final cast = CastService.instance;
    if (!cast.supported) return const SizedBox.shrink();

    return ValueListenableBuilder<CastState>(
      valueListenable: cast.state,
      builder: (context, st, _) {
        final connected = st.isConnected;
        return IconButton(
          icon: Icon(
            connected ? Icons.cast_connected : Icons.cast,
            color: connected ? AppTheme.online : Colors.white,
          ),
          tooltip: connected
              ? 'Casting to ${st.deviceName ?? 'TV'}'
              : 'Cast to TV',
          onPressed: () =>
              connected ? _showConnected(context, st) : _showPicker(context),
        );
      },
    );
  }

  void _showPicker(BuildContext context) {
    final cast = CastService.instance;
    cast.startDiscovery();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => _DevicePickerSheet(
        onDeviceTap: (device) =>
            _castTo(context, sheetContext, device),
      ),
    ).whenComplete(cast.stopDiscovery);
  }

  Future<void> _castTo(
    BuildContext rootContext,
    BuildContext sheetContext,
    GoogleCastDevice device,
  ) async {
    Navigator.of(sheetContext).pop();
    final item = current;
    if (item == null) {
      _snack(rootContext, 'Play a video first, then cast it.');
      return;
    }
    switch (CastMediaMapper.eligibility(item)) {
      case CastEligibility.webMode:
        _snack(rootContext, "Web videos can't be cast.");
        return;
      case CastEligibility.drmDeferred:
        _snack(rootContext, "This DRM-protected series can't be cast yet.");
        return;
      case CastEligibility.ok:
        break;
    }
    final ok = await CastService.instance
        .connectAndCast(device, item, start: localPosition());
    if (!ok && rootContext.mounted) {
      _snack(rootContext,
          CastService.instance.state.value.errorMessage ??
              "Couldn't cast this video.");
    }
  }

  void _showConnected(BuildContext context, CastState st) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.cast_connected,
                  color: AppTheme.primaryRed),
              title: Text(st.deviceName ?? 'Connected'),
              subtitle: Text(st.isCasting ? 'Casting' : 'Connected'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.stop_circle_outlined),
              title: const Text('Stop casting'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                CastService.instance.disconnect();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }
}

/// Bottom sheet listing discovered Cast devices with an empty-state.
class _DevicePickerSheet extends StatelessWidget {
  final void Function(GoogleCastDevice device) onDeviceTap;
  const _DevicePickerSheet({required this.onDeviceTap});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: StreamBuilder<List<GoogleCastDevice>>(
        stream: CastService.instance.devices,
        builder: (context, snapshot) {
          final devices = snapshot.data ?? const <GoogleCastDevice>[];
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Cast to',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w700)),
                ),
              ),
              if (devices.isEmpty)
                const _PickerEmptyState()
              else
                ...devices.map(
                  (d) => ListTile(
                    leading: const Icon(Icons.tv, color: AppTheme.primaryRed),
                    title: Text(d.friendlyName),
                    subtitle: d.modelName != null ? Text(d.modelName!) : null,
                    onTap: () => onDeviceTap(d),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          );
        },
      ),
    );
  }
}

class _PickerEmptyState extends StatelessWidget {
  const _PickerEmptyState();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        children: [
          SizedBox(
            height: 28,
            width: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          SizedBox(height: 16),
          Text('Searching for devices…',
              style: TextStyle(fontWeight: FontWeight.w600)),
          SizedBox(height: 6),
          Text(
            'Make sure your TV and phone are on the same Wi-Fi. '
            'Guest / AP-isolation networks block discovery.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.black54, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
