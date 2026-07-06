# Url Video Player — UI Redesign Spec (dark-first Material 3)

Status: **shipped** in this pass. Android-only. Flutter 3.44 / Dart 3.12, Material 3.
No new packages, no state-management library, no change to `VideoItem` URL identity,
no fork of `ClearKeyResolver`, no change to the DRM/format/cast logic.

This document was produced by a multi-agent research + design workflow (Material 3
tokens · video-player UX patterns · UX code audit · accessibility audit · controls-bug
confirmation → synthesis → 3 adversarial reviews) and then implemented with the
deviations noted in §12.

## 1. Design principles

1. **Red is the accent, not the canvas.** The brand red (`0xFFD32F2F`) stays on the
   AppBar, the primary CTA, the active segment, the progress bar, the favorite heart,
   the LIVE badge and the cast-connected state. Everything else is Material 3 surface
   tone. Keeps the Play Store identity while looking modern.
2. **Dark-first.** Video is watched in dark rooms and the old full-white sheet beside a
   black player was a retina flash between clips. The app ships dark
   (`themeMode: ThemeMode.dark`); a light theme is defined for a future toggle.
3. **The player is the hero.** A real 16:9 stage with the plugin's own controls and a
   one-tap path to landscape fullscreen.
4. **Land on content, not a form.** History/Favorites is the default surface; "Add a
   URL" is an action (FAB → bottom sheet), not a peer tab.
5. **Destructive actions are reversible.** Swipe-to-delete + Undo; a confirm dialog for
   Clear History.
6. **Honesty in the UI.** Cast eligibility limits are surfaced at the point of action
   (unchanged from `docs/cast-to-tv-spec.md`).
7. **Depth via tone, not shadow.** Cards are elevation 0; depth is
   `surface` → `surfaceContainer` → `surfaceContainerHigh`.

## 2. Color

`ColorScheme.fromSeed(seedColor: 0xFFD32F2F, brightness: …)`, then pin
`primary = 0xFFD32F2F`, `onPrimary = white`, and (dark) `surface = 0xFF121212`.

| Role | Used for |
|---|---|
| `primary` (red) | AppBar bg, FilledButton, active segment, progress bar, favorite heart, LIVE badge, cast-connected icon |
| `surface` `0xFF121212` | scaffold |
| `surfaceContainer` | list-tile/card background (elevation 0) |
| `surfaceContainerHigh` | bottom sheets, dialogs, tonal buttons |
| `surfaceContainerHighest` | text-field fill |
| `onSurface` | titles/body on surfaces |
| `onSurfaceVariant` | secondary text (URLs, meta), resting icons |
| `outlineVariant` | hairline dividers, field borders |
| `error`/`onError` | swipe-to-delete panel |
| `inverseSurface`/`onInverseSurface`/`inversePrimary` | floating snackbars |

Text/icons **over the black player box or a poster thumbnail** stay literal
white / white70 — they sit over media, not a themed surface.

## 3. Typography

Default M3 `Typography.material2021`. AppBar title → `titleLarge`; segment labels →
`labelLarge`; tile title → `titleMedium`; tile URL → `bodySmall`; tile meta
(source • resolution • "2h ago") → `labelSmall`; empty-state → `titleMedium`/`bodyMedium`.
No `fontSize:` literals on themed surfaces.

## 4. Screen structure

```
Scaffold (dark surface; red AppBar)
├─ AppBar: "Url Video Player" · [CastButton] · [⋮ "More options"]
├─ Body (Column, SafeArea top:false):
│   ├─ ① PLAYER STAGE — edge-to-edge, AspectRatio 16:9, black
│   │     AnimatedSwitcher (150ms, 0ms under reduce-motion) over CastState:
│   │       · casting        → CastMiniController        (key 'cast')
│   │       · _current==null → idle poster               (key 'idle')
│   │       · else           → VideoPlayerView(key: url) (built-in controls + fullscreen)
│   ├─ ② SegmentedButton<int> [ History | Favorites ] — red selected
│   └─ ③ IndexedStack(index=_contentIndex) of two RefreshIndicator lists
│         HistoryTile → tap=play · swipe-left=delete(+Undo) · trailing heart
└─ FloatingActionButton.extended "Add URL"
      → showModalBottomSheet(isScrollControlled, drag handle):
          Title · URL (+ Paste) · [Advanced ▸ User-Agent] · full-width red "PLAY"
```

Removed: the fake "HD Quality" status pill, the PLAYER form tab, the `TabController` /
`TabBarView`, `SingleTickerProviderStateMixin`, and the full-red scaffold.
Kept: red brand, `ValueNotifier`/`setState` only, URL identity, `ClearKeyResolver`
sharing, the cast-honesty snackbars, `better_player_plus`.

## 5. Player (`VideoPlayerView`)

- `BetterPlayerConfiguration`: `autoPlay`, `fit: contain`, **`aspectRatio: 16/9`**,
  **`autoDetectFullscreenDeviceOrientation: true`**, `handleLifecycle`,
  `autoDispose: false`, `allowedScreenSleep: false`. The `_generation` stale-guard and
  manual teardown are untouched.
- `BetterPlayerControlsConfiguration`: `enablePlayPause`, **`enableSkips`** (±10s via
  `forward/backwardSkipTimeInMilliseconds = 10000`), progress bar + drag + text,
  **`enableFullscreen`**, `enableMute`, `enablePlaybackSpeed`, `enableOverflowMenu`,
  `enableRetry`, `enablePip: false` (not wired in the manifest), `enableSubtitles: false`.
  Brand: red played/handle/loading, white icons, `controlBarColor: black54`, buffered
  white38.
- Pre-controller state → red spinner + `Loading "<title>"…`.
- Error state (`_ErrorBox`) gains an **Edit URL** action that reopens the Add-URL sheet
  pre-filled, alongside Retry.
- Fullscreen is the plugin's own route; the inline scaffold stays portrait. The app is
  **not** globally orientation-locked.

The local skip is genuinely relative (`skipForward/skipBack` seek `position ± 10s`
clamped to `[0, duration]`); the cast skip is fixed in §9.

## 6. Cast mini-controller

Compact, scroll-safe (never overflows the fixed 16:9 stage at large text scale):
cast glyph + **LIVE badge** (when `mediaInformation.duration` is null/zero) · title ·
"On <device>" · transport row (⏮10 · play/pause · ⏭10 · stop) · labeled volume slider.

- a11y: every transport button has a `tooltip` (= semantics name) and a **48dp** target
  (`minWidth/minHeight: 48`); the volume `Slider` is wrapped in
  `Semantics(label:'Cast volume')` with a `semanticFormatterCallback`; decorative glyphs
  are in `ExcludeSemantics`.
- Uses the global `sliderTheme` (local `SliderTheme` wrapper removed).

## 7. History / Favorites tiles

- Card inherits themed `surfaceContainer` (elevation 0). Title `onSurface`, URL/meta
  `onSurfaceVariant`, plus a relative-time token ("2h ago") from `addedAt`.
- Trailing = a single favorite heart (red when favorited, `onSurfaceVariant` outline
  otherwise), tooltip + `semanticLabel` reflect state, ≥48dp (no `VisualDensity.compact`).
- Swipe-left = delete via `Dismissible`; the parent shows an **Undo** snackbar that
  re-`upsert`s the held `VideoItem` (identity is the URL → restores favorite + metadata).
- The row is wrapped in `Semantics(button:true, label:'Play …')` **and** exposes
  `Delete` + `Add/Remove favorite` as `customSemanticsActions`, so screen-reader users
  aren't limited to the (invisible-to-TalkBack) swipe.

## 8. States

- **Idle player**: 16:9 poster — `play_circle_outline` + "No video playing" + a white
  ghost "Add a URL" button opening the FAB sheet.
- **Loading**: red spinner + `Loading "<title>"…`.
- **Player error**: icon + copy + truncated reason + **Retry** + **Edit URL**.
- **Empty History/Favorites**: icon + title + body + an "Add a URL" tonal button;
  scrollable (`AlwaysScrollableScrollPhysics`) so pull-to-refresh works when empty.
- **Cast device-picker empty**: the "Searching for devices…" line is a
  `Semantics(liveRegion:true)`.

## 9. Cast skip fix (the reported "starts from 0:10" bug)

`flutter_chrome_cast` 1.4.6's Android bridge (`GoogleCastSeekOptionsBuilder.fromMap`)
reads only `position`/`resumeState`/`seekToInfinity` and **ignores the `relative`
flag**, always issuing an absolute `setPosition`. So `seekBy(+10s)` executed as an
absolute seek to 0:10.

Fix (`lib/services/cast_service.dart`): compute the absolute target ourselves from the
synchronous `GoogleCastRemoteMediaClient.instance.playerPosition`, add the delta, clamp
to `[0, mediaStatus.mediaInformation.duration]`, and issue an absolute seek. No cached
field or stream subscription is needed. The local `better_player` skip was already
relative and is unchanged.

**Passive-disconnect note:** `CastService` now exposes a `passiveDisconnects`
`ValueNotifier<int>` bumped only when the receiver/remote ends the session on its own
(guarded by an `_endingByUser` flag so a user-initiated `disconnect()` does not fire it).
`HomeScreen` listens and shows a "Cast disconnected." snackbar.

**Honest cast-failure detection (no blank-TV "casting").** The default Styled Media
Receiver silently shows its idle splash for streams it can't handle (HEVC, or
token'd/User-Agent-gated live HLS), parking them in `buffering`/`paused`/`idle` with
no explicit error. `connectAndCast` therefore does not claim to be casting until
`_awaitPlaybackStarted` sees the receiver actually reach **`playing`** — the only
trustworthy signal (buffering/paused are NOT accepted). If it errors or never reaches
`playing` within ~15s, the session is ended (`_endSessionQuietly`, so the TV returns
home) and an `error` state carries a plain-language message ("Your TV's built-in
receiver couldn't play this stream … still playing on your phone"); the UI falls back
to local playback. `_onSessionChanged` only reacts to drops of an *established* session
(connected/casting) so it can't clobber that error state mid-handshake. Verified on
real hardware (Xiaomi Google TV): the ClearKey **DASH VOD proxy** reaches `playing` and
plays the decrypted series on the TV; the beIN/nazika **live HLS** never reaches
`playing` and falls back cleanly instead of stranding a blank cast splash.

## 10. Accessibility (WCAG 2.2 AA)

- All icon-only buttons have tooltips (= names) and ≥48dp targets (cast transport,
  favorite, overflow, paste).
- Contrast fixed at source: muted text on themed surfaces uses `onSurfaceVariant`; solid
  white is used only over the black letterbox/poster. Verified palette ratios:
  onSurface/surface ≈ 14.5, onSurfaceVariant/surface ≈ 11.0 (AAA); white-on-red ≈ 5.0 (AA).
- Favorite state, delete, and volume/seek are exposed to semantics.
- Reduce-motion: the stage `AnimatedSwitcher` collapses to `Duration.zero`; genuine
  loading spinners are kept.

## 11. Non-goals (scope guard)

No PiP (manifest not wired), no custom cast receiver, no brightness/volume swipe
gestures, no search/filter, no new packages, no in-app light/dark toggle UI (light theme
defined but not surfaced), no change to the DB schema, `LinkParser`, `ClearKeyResolver`,
or `VideoItem` identity.

## 12. Deviations from the synthesized plan (implemented reality)

1. **No remote seek scrubber in the cast mini-controller (deferred).** The reviewers
   flagged real RenderFlex-overflow risk from stacking a scrubber onto the dense column
   inside the fixed 16:9 stage. The transport ±10s + play/pause + stop + volume give full
   control; a live-updating scrubber is deferred to avoid a half-working, overflow-prone
   widget. The panel is `SingleChildScrollView`-wrapped as a belt-and-braces guard.
2. **Deep-link handling stays frame-safe.** A non-autoplay shared link is persisted to
   history (current behavior preserved) rather than auto-opening the Add-URL sheet — a
   `showModalBottomSheet` during the cold-start `getInitialLink` (in `initState`) would
   assert before the first frame. Autoplay links play immediately, as before.
3. **Passive cast-disconnect** is implemented via the `passiveDisconnects` notifier +
   `_endingByUser` guard (see §9) rather than a raw state-transition listener, so it does
   not fire on a user-initiated Stop.
