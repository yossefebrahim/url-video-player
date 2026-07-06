# Feature Spec: "Cast to Google TV" for Url Video Player (info.t4w.vp)

Status: Draft for implementation
App: `info.t4w.vp` (Flutter 3.44, Java 17, Kotlin-DSL Gradle, better_player_plus/ExoPlayer)
Target sink: Google TV / Chromecast-built-in devices on the same Wi-Fi

---

## 1. Goal & Non-Goals

### Goal
Add a **Cast button** to the app that:
1. Discovers Google TV / Chromecast-built-in devices on the local Wi-Fi.
2. Connects to a chosen device.
3. Plays the **current** `VideoItem` on that device (handoff, not mirroring), starting from the current local position.
4. Offers basic remote controls: **play / pause / seek / stop / volume**.
5. Degrades gracefully when no device is found, or when the current stream cannot be cast.

### Non-Goals
- **Screen mirroring.** Cast is a URL handoff; the TV fetches the media itself.
- **iOS.** Android-only target for now.
- **A queue / up-next.** Single current item only.
- **Guaranteeing every stream casts.** Section 5 is explicit about what will and will not play on the default receiver vs. a custom receiver.
- **Building a custom CAF Web Receiver in Phase 1.** Deferred to Phase 2 (Section 3).

---

## 2. Chosen Library

**`flutter_chrome_cast: ^1.4.6`** (pub package, native id `com.felnanuke.google_cast`).

### Why
- Only actively-maintained (2025-2026) Flutter Cast package that **wraps Google's native CAF SDK** (`play-services-cast-framework`) on Android, so discovery / session / reconnection are Google's code.
- Explicitly models **HLS and DASH** stream types plus MP4 via `GoogleCastMediaInformation.streamType` / `contentType`.
- Forwards **`customData`** on `loadMedia` and supports a **custom receiver application id** — the two levers needed for the Phase-2 token / User-Agent / ClearKey cases.
- Stream-based Dart API (`devicesStream`, `mediaStatusStream`) maps cleanly onto `StreamBuilder`.

### Rejected alternatives
| Package | Verdict |
|---|---|
| `cast` 2.1.0 | Pure-Dart CASTV2 socket, no `loadMedia`/HLS/DASH/customData helpers, ~2y stale. |
| `flutter_cast_framework` 0.0.1-alpha | Self-declared abandoned POC, no HLS/DASH/DRM story. |
| `flutter_cast_framework_v2` 0.0.9 | Unverified-uploader fork of the above POC. |
| `google_cast` | Does not exist on pub.dev (404). |

### Honest caveat (applies to any package)
**What actually plays depends on the RECEIVER, not the sender.** The package choice is orthogonal to the default-vs-custom-receiver split. See Section 5.

---

## 3. Scope Split (be honest)

### Phase 1 — ships now, DEFAULT receiver (`CC1AD845`)
| Content | Casts in Phase 1? | Notes |
|---|---|---|
| Plain progressive MP4 (H.264/AAC), public, no UA requirement | ✅ Yes | The safe path. Custom User-Agent is NOT honored (Chromium forbidden header). |
| Unencrypted HLS / DASH VOD | ✅ Yes | Works if publicly reachable and codecs are supported by the device. |
| Token'd AES-128 HEVC live HLS (`.json` manifest, `.jpg` segments) | ⚠️ Best-effort, likely fails | HEVC is device-dependent and unsupported in MPEG-TS; disguised extensions and no header hook put it at real risk on the default receiver. Attempt + graceful fallback; flag as Phase-2 target. |
| Series MPEG-DASH + ClearKey CENC DRM (`mpdUrl###k:kid`) | ❌ No | Default receiver has zero DRM hooks. Gated OFF with an explanatory message. |

Phase 1 delivers real value for the common case (MP4 + unencrypted HLS/DASH) and wires **all** the plumbing (customData, contentType/streamType mapping, state model, UI) so Phase 2 is a receiver swap, not a rewrite.

### Phase 2 — DEFERRED, requires a registered CUSTOM CAF Web Receiver
- Register one custom receiver → get a custom App ID → swap `CC1AD845` in `CastOptionsProvider.kt` and the Dart init.
- **ClearKey DASH series:** receiver reads `{kid,key}` from `customData`, sets `playbackConfig.protectionSystem = ContentProtection.CLEARKEY` with an EME ClearKey JWK.
- **AES-128 HEVC live HLS:** receiver sets `contentType` + `hlsSegmentFormat`/`hlsVideoSegmentFormat` for disguised extensions; gate HEVC per-device with `canDisplayType()`. **Hard blocker:** HEVC-in-TS is unsupported on Cast — server must repackage to fMP4/CMAF or transcode to H.264.
- **Header/UA:** custom non-UA headers via `manifestRequestHandler`/`segmentRequestHandler`; move any UA-based auth to URL query tokens.

---

## 4. Architecture

```
main()
  └─ GoogleCastContext.setSharedInstanceWithOptions(appId: CC1AD845)   // Phase 1

lib/services/cast_service.dart      ← NEW  singleton, owns CAF
  ├─ CastState (reactive)           ← idle | discovering | connecting | connected | castingMedia | error
  ├─ startDiscovery() / stopDiscovery()
  ├─ devicesStream  (proxied from GoogleCastDiscoveryManager)
  ├─ connect(device) / disconnect()
  ├─ castItem(VideoItem, startPosition)      ← builds GoogleCastMediaInformation
  ├─ play() / pause() / seek(Duration) / stop() / setVolume(double)
  └─ mediaStatusStream (position, playState, volume) for the mini-controller

lib/services/cast_media_mapper.dart ← NEW  VideoItem → GoogleCastMediaInformation
  └─ reuses ClearKeyResolver.resolve()/sniffFormat() for contentType + streamType

lib/widgets/cast_button.dart        ← NEW  AppBar action + device-picker sheet
lib/widgets/cast_mini_controller.dart ← NEW inline transport controls

WIRING:
  home_screen.dart
    ├─ AppBar.actions: [ CastButton(current: _current), PopupMenuButton ]
    ├─ _playerBox(): if CastService.isCasting → CastMiniController else VideoPlayerView
    └─ on session start: capture local position, pause/tear down local controller,
       CastService.castItem(_current, position); on disconnect: resume local.
```

### Reactive cast-state model
```dart
enum CastPhase { idle, discovering, connecting, connected, castingMedia, error }

class CastState {
  final CastPhase phase;
  final String? deviceName;      // connected device
  final String? errorMessage;
  bool get isCasting;            // phase == castingMedia
}
```
`CastService` exposes `ValueListenable<CastState>`. The AppBar `CastButton` and `_playerBox` both listen; no polling.

---

## 5. Android Native Changes

### 5.1 Gradle — `android/app/build.gradle.kts`
Add a `dependencies { }` block:
```kotlin
dependencies {
    implementation("com.google.android.gms:play-services-cast-framework:22.3.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.mediarouter:mediarouter:1.7.0")
}
```
**minSdk:** Cast needs ≥ 24; Flutter 3.44's `flutter.minSdkVersion` is already 24. If it resolves lower, pin `minSdk = 24`.

### 5.2 Manifest — `android/app/src/main/AndroidManifest.xml`
At `<manifest>` root:
```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/>
```
Inside `<application>`:
```xml
<meta-data
    android:name="com.google.android.gms.cast.framework.OPTIONS_PROVIDER_CLASS_NAME"
    android:value="info.t4w.vp.CastOptionsProvider" />
```
Existing INTERNET / ACCESS_WIFI_STATE / ACCESS_NETWORK_STATE already cover mDNS discovery. Register only ONE options provider.

### 5.3 Kotlin — `android/app/src/main/kotlin/info/t4w/vp/CastOptionsProvider.kt` (NEW)
```kotlin
package info.t4w.vp

import android.content.Context
import com.google.android.gms.cast.framework.CastOptions
import com.google.android.gms.cast.framework.OptionsProvider
import com.google.android.gms.cast.framework.SessionProvider

class CastOptionsProvider : OptionsProvider {
    override fun getCastOptions(context: Context): CastOptions =
        CastOptions.Builder()
            .setReceiverApplicationId("CC1AD845") // Phase 1 default receiver.
            .build()                              // Phase 2: swap for custom App ID.
    override fun getAdditionalSessionProviders(context: Context): List<SessionProvider>? = null
}
```

### 5.4 AppCompat theme
`flutter_chrome_cast` renders the Cast affordance as a **Flutter widget**, so we do NOT add a native `MediaRouteButton`; the current themes are fine.

---

## 6. Dart API Surface (verify names against installed 1.4.6)

- `GoogleCastContext.instance.setSharedInstanceWithOptions(...)` once in `main()`.
- `GoogleCastDiscoveryManager` → `startDiscovery()`, `devicesStream`.
- `GoogleCastSessionManager` → `startSessionWithDevice(device)`, `endSession()`, `currentSession`.
- `GoogleCastRemoteMediaClient` → `loadMedia(mediaInfo)`, `play()`, `pause()`, `seek(...)`, `stop()`, `mediaStatusStream`.
- `GoogleCastMediaInformation(contentId, contentType, streamType, metadata, customData)`.

### Cast-eligibility check
```dart
enum CastEligibility { ok, drmDeferred, webMode }

CastEligibility castEligibility(VideoItem item) {
  if (item.mode == PlayerMode.web) return CastEligibility.webMode;
  if (ClearKeyResolver.resolve(item.url).isEncrypted) return CastEligibility.drmDeferred;
  return CastEligibility.ok;
}
```

---

## 7. Mapping the Current Stream → Cast Media

`cast_media_mapper.dart` reuses `ClearKeyResolver` (no duplicate format logic):
- Resolve + `sniffFormat` (disguised `.json`) → `format`.
- `contentType`: `dash` → `application/dash+xml`; `hls` → `application/vnd.apple.mpegurl`; else `video/mp4`.
- `streamType`: live `.json` HLS → LIVE; MP4/DASH VOD → BUFFERED.
- Always forward `userAgent` + `clearKey` in `customData` for Phase-2 forward-compat.

### Honest notes on headers / customData
- **User-Agent is a Chromium forbidden header** — NOT applied by either receiver. Any origin that *requires* the UA will 403 on the TV. Design auth around URL query tokens.
- The **default receiver ignores `customData`**; it's only meaningful to the Phase-2 custom receiver.

---

## 8. Graceful Behavior

| Situation | Behavior |
|---|---|
| No devices found | Picker sheet shows "No devices found. Make sure your TV and phone are on the same Wi-Fi." Keep discovering. |
| `PlayerMode.web` item | Cast button hidden/disabled ("Web videos can't be cast."). |
| ClearKey DASH (`isEncrypted`) | Cast button disabled ("DRM-protected series can't be cast yet."). No broken load. |
| Load fails on receiver | Snackbar "Couldn't cast this video on your TV," disconnect media, resume local playback. |
| Session drops / TV off | State → `idle`; UI swaps back to local player; snackbar "Cast disconnected." |
| Cast starts while local playing | Capture local position, pause + tear down local controller, then `castItem(..., start: pos)`. |
| Cast stops | Resume local player from last remote position. |

---

## 9. Test Plan

### Unit (host, `flutter test`)
- `cast_media_mapper_test.dart`: MP4 → `video/mp4` + BUFFERED; `.m3u8` → mpegurl; `.mpd` → dash+xml; `###k:kid` → `customData.clearKey` populated and eligibility `drmDeferred`.
- `cast_eligibility_test.dart`: web → `webMode`; encrypted → `drmDeferred`; plain → `ok`.
- `cast_state_test.dart`: state-machine transitions and error paths with a faked facade.
- No regression: existing `sqflite` / `ClearKeyResolver` tests still green.

### On-device (requires a Chromecast/Google TV on Wi-Fi)
1. Cast button appears; connect succeeds.
2. Plain public MP4 casts; play/pause/seek/stop/volume drive the TV.
3. Position handoff both directions.
4. Unencrypted HLS/DASH VOD casts.
5. Token'd AES-128 HEVC live HLS: attempt + document + graceful fallback.
6. ClearKey DASH: button disabled with the DRM message (no crash).
7. No-device / AP-isolation Wi-Fi: empty-state guidance.
8. Release build (R8): OptionsProvider not stripped; casting works.

---

## 10. Acceptance Checklist
- [ ] `flutter_chrome_cast: ^1.4.6` added; `pub get` clean; app builds.
- [ ] Gradle deps + manifest OPTIONS_PROVIDER + `CastOptionsProvider.kt`.
- [ ] `GoogleCastContext` initialized once in `main()`.
- [ ] Cast button in AppBar; state-reactive; device-picker sheet.
- [ ] `CastService` + `CastState` with play/pause/seek/stop/volume.
- [ ] `cast_media_mapper` maps MP4/HLS/DASH + forwards UA/clearKey in `customData`.
- [ ] Local player paused/torn down on session start; position handed off.
- [ ] Inline `CastMiniController` shown when casting.
- [ ] Graceful states: no-device, web-disabled, DRM-deferred, load-failure fallback, disconnect resume.
- [ ] Unit tests pass; existing tests green.
- [ ] Docs note honest limits: UA not castable; ClearKey/HEVC-live need Phase-2 custom receiver.

---

## 11. Key Risks (from research)
1. **User-Agent passthrough is impossible on Chromecast** (forbidden header). UA-gated URLs 403 on the TV.
2. **HEVC is device-dependent** and unsupported in MPEG-TS containers — live HLS may fail on the receiver until repackaged to fMP4/CMAF.
3. **Default receiver has zero DRM hooks** — ClearKey DASH will not cast in Phase 1.
4. **Cast is a handoff, not mirroring** — the TV fetches the URL itself; signed URLs must stay valid and be publicly reachable.
5. **mDNS discovery** needs same subnet; guest/AP-isolation Wi-Fi breaks it; zero devices is a valid state.
6. **flutter_chrome_cast is community-maintained** — verify API names against installed 1.4.6; may need a plugin Gradle namespace bump for the app's AGP toolchain.

---

## 12. Implementation Status (Phase 1 — shipped)

Built and verified on device (Samsung SM-A346E). Deviations from the draft above, all simplifications:

- **No custom Kotlin `CastOptionsProvider`.** The plugin bundles `com.felnanuke.google_cast.GoogleCastOptionsProvider`, which builds `CastOptions` from the Dart `setSharedInstanceWithOptions(appId:)` call. We register **that** class in the manifest `OPTIONS_PROVIDER_CLASS_NAME` meta-data — the receiver id lives in Dart (`CastService.defaultReceiverAppId = 'CC1AD845'`). One manifest line; zero app Kotlin.
- **No extra Gradle deps.** `play-services-cast-framework` (+ appcompat/mediarouter) come transitively from the plugin; the app built and ran without pinning them. `minSdk` (24, from Flutter) already satisfies Cast.
- **No `MediaNotificationService` / `FOREGROUND_SERVICE_MEDIA_PLAYBACK`** added — basic casting works without them; revisit if a media notification is wanted.

**Files created:** `lib/services/cast_service.dart`, `lib/services/cast_media_mapper.dart`, `lib/widgets/cast_button.dart`, `lib/widgets/cast_mini_controller.dart`.
**Files changed:** `pubspec.yaml`, `lib/main.dart`, `lib/screens/home_screen.dart`, `lib/widgets/video_player_view.dart` (added `positionSink`), `android/app/src/main/AndroidManifest.xml`.

**Verified:** Cast button renders; tap opens the picker; CAF mDNS discovery starts (`_googlecast._tcp`) and stops cleanly on close (multicast lock released); empty-state guidance shows; app init + teardown crash-free; `flutter analyze` clean; unit tests green (`cast_media_mapper_test.dart`).

**Not yet verified (needs a Google TV on the Wi-Fi):** actual connect + media load + remote controls + position hand-off.

---

## 13. DRM series casting — on-device decrypt proxy (shipped, replaces the custom receiver)

Instead of a hosted custom CAF receiver (which needs a paid Cast Console registration), ClearKey **CENC DASH** series are now cast via a **local decrypt proxy on the phone**. This needs no sign-up and no hosting.

**How it works**
1. `ClearKeyResolver` exposes the raw 16-byte content key (`keyBytes`) from the `###k:kid` hand-off.
2. When casting an encrypted `.mpd`, `CastService` starts `CastProxyServer` (`dart:io HttpServer` bound to the phone's LAN IP) and casts `http://<phone-ip>:<port>/manifest.mpd` to the default receiver.
3. The Chromecast fetches from the phone. The proxy:
   - rewrites the manifest — strips `<ContentProtection>`, points every `SegmentTemplate` at the proxy, preserves `SegmentTimeline`;
   - proxies each init/media segment from the real origin and **decrypts CENC in place** (`CencDecryptor`, pointycastle AES-CTR): renames `encv`→`avc1`/`enca`→`mp4a`, `sinf`/`senc`/`saiz`/`saio`/`sbgp`/`sgpd`/`pssh`→`free` (size-preserving, no offset recompute), and AES-CTR-decrypts `mdat` (subsample-aware for video, whole-sample for audio);
   - sends CORS headers (the receiver runs in a browser and fetches cross-origin).

This also **transparently solves the User-Agent + token problems**: the phone fetches upstream with the right headers; the TV only ever talks to the phone.

**Validation (desktop, no TV):** the Dart decryptor's output is **byte-identical to ffmpeg `-decryption_key`** (same decoded-frame MD5), audio + video decode cleanly, and **VLC** (a real DASH client, like the Chromecast's Shaka) plays the full pipeline through the proxy end-to-end (h264 + aac). Locked in by known-answer unit tests in `test/cenc_decryptor_test.dart`.

**New files:** `lib/services/cenc_decryptor.dart`, `lib/services/cast_proxy_server.dart` (both pure Dart), `tool/cenc_validate.dart`, `tool/proxy_validate.dart`, `test/fixtures/cenc_video_*.mp4`.
**Dependency added:** `pointycastle` (pure-Dart AES).
**Still needs a TV to verify the final on-glass playback.** HEVC-in-TS live (beIN) is a separate codec problem, unchanged by this.
