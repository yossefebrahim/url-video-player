import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Ref-counted wrapper around [WakelockPlus], which is a single process-global
/// flag with no ref-counting of its own.
///
/// Two independent owners keep the screen awake — the local [VideoPlayerView]
/// while a video plays, and [CastService] while a cast proxy is serving the TV.
/// If each called `WakelockPlus.enable()/disable()` directly, one owner's
/// teardown would clear the other's lock (e.g. a player disposing mid-cast would
/// silently drop the proxy's wakelock and let Doze stall the stream). This
/// coordinator holds the OS lock while *any* owner has acquired it and only
/// releases it when the last owner lets go.
class WakelockCoordinator {
  WakelockCoordinator._();
  static final WakelockCoordinator instance = WakelockCoordinator._();

  final Set<Object> _owners = {};

  /// Marks [owner] as needing the screen awake. Idempotent per owner.
  Future<void> acquire(Object owner) async {
    final wasEmpty = _owners.isEmpty;
    _owners.add(owner);
    if (wasEmpty) await _apply(true);
  }

  /// Releases [owner]'s claim; the OS lock drops only when no owner remains.
  Future<void> release(Object owner) async {
    if (!_owners.remove(owner)) return;
    if (_owners.isEmpty) await _apply(false);
  }

  Future<void> _apply(bool enable) async {
    try {
      if (enable) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (e) {
      debugPrint('WakelockCoordinator ${enable ? 'enable' : 'disable'} failed: $e');
    }
  }
}
