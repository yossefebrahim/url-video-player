# Google TV Performance & Lifecycle Audit

**Date:** 2026-07-07 · **Branch:** `fix/cast-data-uri-key` (TV mode uncommitted)
**Scope:** the full app lifecycle on Android TV / Google TV — cold start → Ostora
hand-off → playback → steady state → background → exit — with every finding
weighed against a low-resource TV (≈1 GB RAM, 4 slow cores, weak GPU, shared
network). Phone-only paths are noted but not the focus.

---

## 1. Lifecycle map (as implemented today)

### Phase A — process start (both phone and TV)

| Step | Where | Cost on a low-end TV |
|---|---|---|
| A1. Android process + Flutter engine init | `MainActivity` / LaunchTheme | ~1–2 s (fixed cost; dex is unshrunk, see F-11) |
| A2. `WidgetsFlutterBinding.ensureInitialized()` | [main.dart:8](../lib/main.dart) | negligible |
| A3. **`await CastService.instance.ensureInitialized()`** — CAF context creation on the platform thread, **before `runApp`** | [main.dart:10](../lib/main.dart), [cast_service.dart:83](../lib/services/cast_service.dart) | 100 ms–1 s+ (GMS round-trip). Blocks the first frame. On a TV it is 100 % waste — the TV *is* a receiver, it never casts out (F-2) |
| A4. `runApp` → first frame (black scaffold while `_isTv == null`) | [home_screen.dart:369](../lib/screens/home_screen.dart) | good — no touch-UI flash on TV |

### Phase B — hand-off → playing (the TV-critical path)

| Step | Where | Cost |
|---|---|---|
| B1. `HomeScreen.initState` → `_reload()` — SQLite open + **2 full-table queries** for a UI that never renders on TV | [home_screen.dart:53](../lib/screens/home_screen.dart) | disk + CPU on the zap path (F-4) |
| B2. `PlatformInfo.isTv()` channel round-trip (cached afterwards) | [platform_info.dart:21](../lib/services/platform_info.dart) | one-time, small — correct ordering (must precede the first link) |
| B3. `getInitialLink()` → `LinkParser` → `_openItem` | [home_screen.dart:66](../lib/screens/home_screen.dart) | small |
| B4. **`await _db.upsert(item)` + `await _reload()` (2 more full-table queries) before `_play`** | [home_screen.dart:102-107](../lib/screens/home_screen.dart) | DB writes sit between the intent and the video (F-4) |
| B5. TV branch: `popUntil` + push `TvPlayerScreen`, then **`_enrichThumbnail(item)`** — native `MediaMetadataRetriever` opens a *second connection to the same stream* and decodes a full-res frame while ExoPlayer is starting | [home_screen.dart:122-138](../lib/screens/home_screen.dart), [MainActivity.kt:129](../android/app/src/main/kotlin/info/t4w/vp/MainActivity.kt) | competes for network, CPU and (on some SoCs) a codec instance during startup; the thumbnail is never shown on TV (F-3) |
| B6. `VideoPlayerView._setUp`: `ClearKeyResolver.resolve` → `probe()` — network GET, reads up to 64 KB, 10 s timeout | [video_player_view.dart:108-123](../lib/widgets/video_player_view.dart), [clear_key.dart:145](../lib/services/clear_key.dart) | one origin fetch |
| B7. `LiveHlsProxy.wrap` (first use binds the loopback server) → ExoPlayer fetches the playlist **again** through the proxy | [live_hls_proxy.dart:46](../lib/services/live_hls_proxy.dart) | the playlist is downloaded twice per (re)connect (F-6) |
| B8. `BetterPlayerController` create → texture + ExoPlayer + **`DefaultLoadControl` with `maxBufferMs = 6,553,600` (~109 minutes)** — the plugin default, sent unconditionally because the app passes no `bufferingConfiguration` | [video_player_view.dart:143](../lib/widgets/video_player_view.dart) | **the single biggest memory risk on a 1 GB TV** (F-1) |
| B9. `initialized` event → wakelock acquired, duration/resolution patched to DB (+ another `_reload()`) | [video_player_view.dart:196-206](../lib/widgets/video_player_view.dart) | fine |

### Phase C — steady state (live channel playing)

- ExoPlayer re-requests `/pl` every playlist refresh (~2–6 s); the proxy re-fetches
  the origin and re-rewrites the playlist on the main isolate
  ([live_hls_proxy.dart:76](../lib/services/live_hls_proxy.dart)). Cheap for normal
  playlists; unbounded for a hostile/broken one (F-7).
- `progress` events every ~250–500 ms; in `TvPlayerScreen` they `setState` the whole
  screen while the HUD/menu is visible ([tv_player_screen.dart:156-166](../lib/screens/tv_player_screen.dart)) (F-8).
- The plugin's **touch controls subtree is still built and ticking in `tvMode`** —
  only individual features are disabled, `showControls` stays `true`
  ([video_player_view.dart:162-188](../lib/widgets/video_player_view.dart)) (F-5).
- Wakelock held via ref-counted `WakelockCoordinator` — correct.

### Phase D — errors / reconnect

- `exception` → `onErrorChanged(true)` → up to 5 auto-retries, 3 s apart; each retry
  **remounts `VideoPlayerView`** (keyed `url#attempt`) → full teardown → full
  re-setup **including a fresh 64 KB probe** (F-6). Old controller force-disposed —
  correct (no double decoder).
- Channel-zap: `popUntil` before push — correct (no stacked players).

### Phase E — background / exit

- HOME pressed: `handleLifecycle: true` pauses playback but **keeps the ExoPlayer
  instance, its decoder, and its (potentially enormous, see F-1) buffer resident**
  ([video_player_view.dart:154](../lib/widgets/video_player_view.dart)). On Google TV
  the LMK kills cached apps aggressively — holding tens of MB while paused is how the
  app gets killed instead of resuming (F-9).
- BACK: `SystemNavigator.pop()` exits to Ostora/launcher. Process stays cached with
  the `LiveHlsProxy` server still bound (acceptable; it's idle).
- Dispose paths (`_teardown`, timers, focus nodes, listeners) are all correct — the
  15-agent review already fixed the leaks here.

---

## 2. Findings, prioritized

| # | Sev | Finding | Area |
|---|---|---|---|
| F-1 | **P0** | ExoPlayer `maxBufferMs` defaults to **~109 minutes** (plugin default `6553600` ms); buffer grows until the allocator cap (~130 MB for A/V) — an OOM/LMK magnet on a 1 GB TV, worst on VOD/movies | memory |
| F-2 | **P0** | `main()` **awaits** Cast CAF init before `runApp` — delays first frame on every launch; entirely useless on TV (a TV never casts out) | startup |
| F-3 | **P1** | TV play path fires `_enrichThumbnail` → `MediaMetadataRetriever` opens a second connection to the stream + decodes a full-res frame during player startup, for a thumbnail the TV UI never shows | startup / CPU |
| F-4 | **P1** | DB `upsert` + two full `_reload()` list queries sit on the intent→video critical path; the lists never render on TV | startup |
| F-5 | **P1** | `tvMode` leaves the plugin's touch-controls subtree mounted (`showControls` stays true) — dead widgets + periodic ticks under the custom D-pad UI | CPU / memory |
| F-6 | **P2** | Playlist fetched twice per (re)connect (probe + ExoPlayer-via-proxy); every auto-retry re-probes — up to 5×64 KB + latency on flaky live streams | startup / network |
| F-7 | **P2** | `LiveHlsProxy._fetch` and `ClearKeyResolver` probe have no response-size cap on the playlist body (`join()` into one String) — a broken origin can balloon the heap | hardening |
| F-8 | **P2** | `TvPlayerScreen._onPlayerEvent` calls `setState` on every `progress` tick while HUD/menu is up — rebuilds the whole screen stack ~2–4×/s | CPU / jank |
| F-9 | **P2** | On TV, backgrounding keeps the decoder + buffers alive (paused); on live streams resume-from-pause is wrong anyway (stale edge). Should tear down on `paused`, reconnect on `resumed` | memory / LMK |
| F-10 | **P3** | Phone: `Image.file` thumbnails decode at full video-frame resolution (no `cacheWidth`) into a 104×64 box; native side also writes the JPEG at frame size | memory (phone) |
| F-11 | **P3** | R8/resource shrinking disabled (`isMinifyEnabled = false`) — bigger dex → slower cold start, more resident RAM. Was disabled for a WorkManager reflection crash; could return with targeted keep rules | startup / memory |
| F-12 | **P3** | Impeller on weak TV GPUs (Mali-G31 class) is unverified — if UI jank is seen on-device, A/B test with Impeller disabled before blaming app code | GPU |
| F-13 | **P3** | `android:banner` points at `ic_launcher` — TV launcher expects a 320×180 banner. Cosmetic, not perf | polish |

---

## 3. Detailed findings & recommended fixes

### F-1 (P0) — Cap ExoPlayer's buffer: the ~109-minute default

`better_player_plus` 1.3.4 defines
`defaultMaxBufferMs = 6553600` (`BetterPlayerBufferingConfiguration`), and the
create call **always** sends min/max/playback values to the native side, where
`CustomDefaultLoadControl` feeds them into media3's `DefaultLoadControl`. Since
[video_player_view.dart:125](../lib/widgets/video_player_view.dart) builds its
`BetterPlayerDataSource` without a `bufferingConfiguration`, every player asks
ExoPlayer to buffer up to ~109 minutes of media, bounded only by the allocator's
target-buffer-bytes (~130 MB for video+audio). On a 1 GB Google TV that is the
difference between comfortable and LMK-killed:

- live 2 Mbps channel: origin only exposes a few segments, so the live case
  mostly survives by accident;
- VOD MP4/HLS (movies opened from history / shared links): the buffer **will**
  grow toward the byte cap.

**Fix** — pass an explicit config in `_setUp`:

```dart
bufferingConfiguration: const BetterPlayerBufferingConfiguration(
  minBufferMs: 15000,
  maxBufferMs: 60000,               // 60 s, not 109 min
  bufferForPlaybackMs: 2000,        // faster channel-zap start
  bufferForPlaybackAfterRebufferMs: 5000,
),
```

≈4–15 MB of media buffer at live bitrates instead of "up to 130 MB". Also
slightly faster start (`bufferForPlaybackMs` 3000→2000). Safe on phones too.

### F-2 (P0) — Unblock `runApp`; skip Cast entirely on TV

[main.dart:7-12](../lib/main.dart): the comment says "never blocks app startup"
but the call is awaited — CAF context creation (a GMS binder round-trip) runs
before the first frame on **every** cold start, including the TV hand-off path
where casting can never be used. `ensureInitialized()` is already called lazily
by `startDiscovery`/`connectAndCast`, so eager init buys nothing except a warm
cache for the phone's cast button.

**Fix (two parts):**

1. `main()`: don't await — resolve the device type first, then init cast only
   off-TV, after the first frame:
   ```dart
   void main() {
     WidgetsFlutterBinding.ensureInitialized();
     runApp(const UrlVideoPlayerApp());
     PlatformInfo.isTv().then((tv) {
       if (!tv) CastService.instance.ensureInitialized(); // fire-and-forget
     });
   }
   ```
2. `CastService.supported` → `Platform.isAndroid && !PlatformInfo.isTvSync`
   (expose the cached bool). Guards every other entry point (discovery, session
   stream) so the CAF/MediaRouter stack is never resident on the TV.

### F-3 (P1) — Don't generate thumbnails on the TV path

[home_screen.dart:137](../lib/screens/home_screen.dart): the TV branch of
`_play` calls `_enrichThumbnail(item)` right after pushing `TvPlayerScreen`.
That spawns a raw `Thread` in `MainActivity.generateThumbnail` which opens a
**second network connection to the same live stream** with
`MediaMetadataRetriever`, demuxes, and decodes a full-resolution frame — during
the seconds ExoPlayer itself is trying to start on 4 slow cores. On most of
these live channels MMR fails anyway (after doing the network+demux work), and
the TV UI never displays thumbnails.

**Fix:** delete the `_enrichThumbnail(item)` call from the TV branch (keep it
on the phone path). Optional phone refinement: skip MMR for URLs whose probe
said "hls live" — it nearly always fails there.

### F-4 (P1) — Get the database off the TV zap path

[home_screen.dart:102-112](../lib/screens/home_screen.dart): `_openItem` awaits
`upsert` (SELECT + INSERT/UPDATE) and then `_reload()` (2 full-table SELECTs)
before `_play`. `initState` also fires `_reload()` at startup, and
`_onPlayerInitialized` fires another after metadata patch. On TV, the
history/favorites lists never render — all of it is pure latency between the
Ostora intent and video.

**Fix:** on TV, play first and persist in the background; make `_reload` a
no-op on TV:

```dart
Future<void> _openItem(VideoItem item, {required bool autoPlay}) async {
  if (_isTv == true) {
    if (autoPlay) _play(item);                 // zap instantly
    unawaited(_db.upsert(item).catchError(...)); // history still recorded
    return;
  }
  // existing phone path unchanged
}
```

(History still works if the TV UI ever gains a browse mode — rows are written,
just not awaited or re-read.)

### F-5 (P1) — `showControls: false` in tvMode

[video_player_view.dart:162-188](../lib/widgets/video_player_view.dart) disables
individual features in `tvMode` but the plugin's Material controls layer is
still constructed (`showControls` defaults to `true`), together with its
visibility timers and periodic progress `setState`s — invisible dead weight
under the custom D-pad HUD.

**Fix:** add `showControls: !tv` to the `BetterPlayerControlsConfiguration`.
Verify D-pad flows on-device afterwards (the custom HUD/menu never relied on
the plugin layer, so this should be purely subtractive).

### F-6 (P2) — Cache the probe verdict; stop re-sniffing on every reconnect

Each `VideoPlayerView` remount (initial + each of up to 5 auto-retries +
manual retries) re-runs `ClearKeyResolver.probe` — a fresh `HttpClient`, a
64 KB read, and a possible 10 s timeout — before rebuilding the player, even
though the verdict (format + `hasInlineDataKey`) is a property of the URL that
doesn't change between retries seconds apart.

**Fix:** memoize `(format, hasInlineDataKey)` per `url+userAgent` in a small
static map (session-lifetime; these URLs are per-session tokens anyway).
Reconnects then skip straight to `LiveHlsProxy.wrap` → controller build,
cutting several seconds off every recovery on flaky channels and removing the
duplicate origin fetch. Bonus: `TvPlayerScreen` reconnects become cheap enough
to shorten `_retryDelay`.

### F-7 (P2) — Cap proxy/probe response bodies

[live_hls_proxy.dart:117-134](../lib/services/live_hls_proxy.dart) `_fetch` does
`response.transform(utf8.decoder).join()` with no size limit (the 12 s timeout
does not bound bytes), and it runs on every playlist refresh for the entire
viewing session. A misbehaving origin (or a redirect to a media file) would be
accumulated into one giant Dart String on the main isolate.

**Fix:** stream with a byte budget (e.g. 4 MB — real playlists are a few KB)
and abort past it. Same treatment already exists implicitly in
`_readHead` (64 KB cap) — this closes the remaining hole.

### F-8 (P2) — Scope HUD repaints in `TvPlayerScreen`

[tv_player_screen.dart:156-166](../lib/screens/tv_player_screen.dart): while the
info bar or menu is visible, every `progress` event `setState`s the whole
screen — `Stack`, `VideoPlayerView` subtree, menu — 2–4×/s on a weak GPU, purely
to refresh a time label.

**Fix:** hold the position in a `ValueNotifier<Duration>` updated from the
event listener and let `_InfoBar`/`_ControlsMenu` watch it via
`ValueListenableBuilder`, so only the label rebuilds. (The existing
`positionSink` plumbing in `VideoPlayerView` is exactly this pattern — reuse it
in tvMode instead of the event-driven `setState`.)

### F-9 (P2) — Tear down the player when the TV app is backgrounded

`handleLifecycle: true` pauses on `AppLifecycleState.paused` but keeps the
native ExoPlayer, its codec, and its buffer alive in the cached process. On
Google TV this both (a) inflates the resident size right when the LMK is
choosing victims, and (b) is semantically wrong for live TV — resuming a
paused live stream plays a stale edge and often stalls into the error path.

**Fix:** in `TvPlayerScreen`, add a `WidgetsBindingObserver`:
`paused/hidden` → dispose the player (reuse `_reconnect`'s teardown half),
`resumed` → bump `_attempt` to remount fresh at the live edge. Combined with
F-6, resume is a cheap proxy-wrap + player build. Keep `handleLifecycle: true`
on the phone/inline path.

### F-10 (P3, phone) — Decode thumbnails at display size

[history_tile.dart:110](../lib/widgets/history_tile.dart): `Image.file` without
`cacheWidth` decodes the JPEG at its stored size — the full video frame (a 1080p
frame ≈ 8 MB decoded, 4K ≈ 33 MB) — for a 104×64 tile, multiplied by visible
rows and retained in the image cache. **Fix:** `cacheWidth: 208` on the
`Image.file`, and in `MainActivity.generateThumbnail` scale the bitmap
(e.g. `Bitmap.createScaledBitmap` to ≤480 px wide) before `compress`, which also
shrinks the disk cache.

### F-11 / F-12 / F-13 (P3) — build & platform notes

- **R8**: re-enabling shrinking (with keep rules for the WorkManager/Cast
  reflection that crashed before) would cut dex size and cold-start I/O on TV.
  Only worth doing with an on-device regression pass of the release APK.
- **Impeller**: if on-device testing shows UI jank (HUD animations, focus
  highlights) on Mali-class GPUs, A/B with Impeller disabled
  (`io.flutter.embedding.android.EnableImpeller` meta-data `false`) before
  optimizing widgets.
- **TV banner**: supply a real 320×180 `android:banner` asset.

---

## 4. How to track the lifecycle (measurement plan)

To make the improvements verifiable (and regressions visible), instrument the
critical path with a tiny trace helper — one `Stopwatch` started in `main()`,
`debugPrint('[trace] <marker> +<ms>')` at:

`main-start` → `runApp` → `isTv-resolved` → `initial-link` →
`play-called` → `tv-screen-pushed` → `setup-start` → `probe-done` →
`proxy-wrapped` → `controller-created` → `player-initialized` →
`first-progress` (≈ first rendered frames).

On-device workflow (TV connected over adb):

```bash
# startup trace (cold start via the Ostora hand-off)
adb shell am force-stop info.t4w.vp
adb logcat -c && adb logcat -s flutter | grep trace

# memory: sample during playback, note "TOTAL PSS", Graphics, and Native Heap
adb shell dumpsys meminfo info.t4w.vp

# UI jank while HUD/menu is up
adb shell dumpsys gfxinfo info.t4w.vp framestats

# LMK pressure / kill events after backgrounding
adb logcat -s ActivityManager | grep -i "info.t4w.vp\|lowmemorykiller"
```

Targets on a 1 GB-class Google TV after the P0/P1 fixes:

| Metric | Before (expected) | Target |
|---|---|---|
| Cold hand-off → first video frame | 6–10 s | ≤ 4–5 s |
| PSS during live playback | 250–400 MB (buffer-dependent) | ≤ 180 MB |
| Reconnect (auto-retry) time | retry delay + probe + setup (~6–8 s) | ~4 s |
| Resident size while backgrounded | full player kept | player torn down |

---

## 5. Suggested implementation order

1. **F-1** buffering config (one const in `video_player_view.dart`; biggest RAM win)
2. **F-2** non-blocking, TV-gated Cast init (`main.dart` + `CastService.supported`)
3. **F-3 + F-4** TV zap path: no thumbnail, no awaited DB work
4. **F-5** `showControls: !tv`
5. **F-6** probe memoization (also makes F-9's resume cheap)
6. **F-8, F-9** HUD repaint scoping; teardown-on-background for TV
7. **F-7, F-10** hardening + phone thumbnail decode size
8. P3 items opportunistically, each with an on-device check

Every step is independently shippable; 1–4 are low-risk and unit-testable
(`flutter analyze && flutter test`), while 6 and 9 want an on-device pass on
the Mi TV per spec §9 before committing.
