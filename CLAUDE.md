# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Url Video Player** (`vp`, package `info.t4w.vp`) — an **Android-only** Flutter app that plays a video from a user-typed URL, a deep link, or a shared/"open with" intent. It keeps a local history + favorites list, enriches entries with a poster thumbnail / duration / resolution, plays ClearKey-DRM streams, and can cast the current video to a Google TV / Chromecast. `android/` is the only platform folder — there is no iOS/web/desktop target.

The `README.md` is the default Flutter template and carries no project information. `docs/cast-to-tv-spec.md` is the real, authoritative design doc for the Cast feature (with an honest scope/limits section) — read it before touching anything cast-related.

## Commands

```bash
flutter pub get                              # install deps
flutter run                                  # run on a connected Android device/emulator
flutter analyze                              # lint (flutter_lints via analysis_options.yaml)
flutter test                                 # all unit tests (run on host, no device needed)
flutter test test/link_parser_test.dart      # a single test file
flutter test --name "de-dupes"               # tests matching a name substring
flutter build apk                            # release APK (currently signed with DEBUG keys — see below)
```

Tests run entirely on the host: the SQLite tests use `sqflite_common_ffi` (`sqfliteFfiInit()` + `databaseFactory = databaseFactoryFfi` in `setUpAll`, and `HistoryDatabase.inMemory()`), and the cast/DRM logic is tested through pure functions (`CastMediaMapper.mediaInfoFor`, `ClearKeyResolver`). No emulator or Chromecast is required for the unit suite; on-device cast behavior is verified manually per spec §9.

## Architecture

Single-screen app. `main.dart` best-effort-initializes `CastService` then runs `HomeScreen`, which is the hub for everything: a 3-tab sheet (**PLAYER** form / **HISTORY** / **FAVORITES**) above an inline player box that swaps between `VideoPlayerView`, `CastMiniController` (while casting), and an empty state.

Services and the database are **singletons accessed via `X.instance`** (e.g. `HistoryDatabase.instance`, `CastService.instance`). There is no DI framework and no external state-management package — reactivity is plain `ValueNotifier`/`ValueListenableBuilder` and `setState`.

Data flow for a played video:
`intent / form input → LinkParser → ParsedLink(VideoItem) → HomeScreen._openItem → HistoryDatabase.upsert → VideoPlayerView (local) or CastService (TV)`, with `MetadataService` and the player's `initialized` event patching thumbnail/duration/resolution back into the DB row afterward.

### The load-bearing cross-file facts (read these before editing)

- **A `VideoItem`'s identity is its URL, everywhere.** `VideoItem.==`/`hashCode` are defined on `url`; the `history` table declares `url TEXT NOT NULL UNIQUE`; favorites are toggled by url; `HistoryDatabase.upsert` de-dupes on url and preserves the existing `favorite` flag + already-captured thumbnail/metadata on re-open. Any change to identity touches the model, the schema, and the upsert/dedup logic together.

- **`ClearKeyResolver` (`lib/services/clear_key.dart`) is the single source of truth for stream format + DRM**, deliberately shared by **both** the local player (`VideoPlayerView`) and the cast path (`CastMediaMapper`) — "no duplicate format logic." It resolves the `<manifestUrl>###<k>:<kid>` ClearKey scheme into a `ResolvedStream` and does byte-level content sniffing for streams handed off with **obfuscated extensions** (e.g. a real HLS playlist served as `…/54_42.json`, segments disguised as `.jpg`). If you change format detection, both playback paths change.

- **The obfuscation formats are bug-for-bug ports of a prior native app** (`info.t4w.vp.view.*`), so hand-offs from sibling apps (e.g. Ostora) resolve identically. `LinkParser` re-implements the `urlplayer://` / `urlvplayer://` custom scheme (host ending in `play` → native player, `web` → web player; `url` param is URL-safe-Base64 → XOR(hardcoded key) → URL-decode), and `ClearKeyResolver._buildClearKeyJson`/`_normalizeBase64` mirror the original `tmpSize211`/`sKey6064`. **Do not "clean up"** the XOR key, base64 normalization, `+`/space handling, or double-decode passes — they are intentionally compatible with the legacy format.

- **Deep links arrive by two paths and are delivered once.** `MainActivity.kt` (launchMode `singleTop`) exposes MethodChannel `info.t4w.vp/deeplink` (`getInitialLink`, consumed once so hot restarts don't replay it) for cold starts and EventChannel `info.t4w.vp/deeplink/events` (`onNewIntent`) for links while running. `DeepLinkService` bridges both to Dart and routes every payload through `LinkParser`. An `activity-alias info.t4w.vp.view.MainActivity` in the manifest catches explicit-component launches that pass the URL via `url`/`agent` intent extras.

- **Cast is Android-only, a URL handoff (not mirroring), and honestly scoped.** `CastService` owns the Google Cast CAF session as a reactive `ValueNotifier<CastState>` (`idle → discovering → connecting → connected → castingMedia`/`error`); every native call is guarded so failure falls back to local playback. The receiver id lives in **Dart** (`CastService.defaultReceiverAppId = 'CC1AD845'`, the default Styled Media Receiver) — there is no custom Kotlin `CastOptionsProvider`; the manifest points CAF at the plugin's `com.felnanuke.google_cast.GoogleCastOptionsProvider`. Known hard limits (see `docs/cast-to-tv-spec.md` §5/§7/§11): **User-Agent is a Chromium forbidden header and is never applied when casting**; the default receiver **ignores `customData`**; ClearKey-DASH and HEVC-in-TS live HLS are gated off / best-effort and deferred to a Phase-2 custom receiver.

- **Metadata enrichment is lazy and non-blocking.** Thumbnails come from the native `generateThumbnail` MethodChannel (`MediaMetadataRetriever`, content-addressed on disk by a stable 64-bit FNV-1a of the URL); duration/resolution come from the player's `initialized` event. Both are patched into the DB row after the fact via `HistoryDatabase.updateMetadata` — never on the play path.

- **`VideoPlayerView` guards against stale async setup with a `_generation` counter.** Setup does network sniffing before building the controller, so a fast URL/UA switch must not let an older setup clobber a newer controller — every async continuation checks `_isStale(gen)`. It uses `autoDispose: false` with manual teardown and toggles `WakelockPlus` around playback.

### Native / build notes

- Java 17 + Kotlin JVM target 17; Gradle **Kotlin DSL**; `namespace`/`applicationId` = `info.t4w.vp`. SDK versions (`minSdk`, `compileSdk`, `targetSdk`, version) all come from the Flutter toolchain — `minSdk` resolves to 24, which Cast requires.
- The `play-services-cast-framework` / `appcompat` / `mediarouter` dependencies are pulled in **transitively by the `flutter_chrome_cast` plugin** and are intentionally *not* pinned in `android/app/build.gradle.kts`.
- **Release builds are currently signed with the debug keystore** (`buildTypes.release.signingConfig = debug`, a leftover TODO) — do not treat a `flutter build apk --release` output as production-signed.
- `usesCleartextTraffic="true"` is set on purpose: users paste arbitrary `http://` stream URLs.

## Key dependencies

`better_player_plus` (ExoPlayer-backed native playback: MP4/HLS/DASH + ClearKey DRM + request headers) · `flutter_chrome_cast` (wraps the native Google Cast CAF SDK) · `webview_flutter` (the `PlayerMode.web` embedded player) · `sqflite` (+ `sqflite_common_ffi` for host tests) · `wakelock_plus` (keep screen awake during playback).
