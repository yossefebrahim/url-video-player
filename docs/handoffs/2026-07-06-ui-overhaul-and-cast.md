# Session handoff — UI overhaul, bug fixes, and live-HEVC casting

**Date:** 2026-07-06
**Device under test:** Samsung SM-A346E (`ANDROID_SERIAL=192.168.9.2:45349`)
**Cast target:** Xiaomi Google TV — friendly name "TV", model `MiTV-MOOR2`
**Repo:** `github.com/yossefebrahim/url-video-player` (public), branch `main`

This is a complete A→Z record of the session: what was asked, what shipped, how it
was verified on-device, and the exact state of the in-progress live-cast work.

---

## 1. What the user asked for (in order)

1. **UX overhaul** using Material Design.
2. **Fix the skip button** — "+10s starts from 0:10 instead of skipping forward."
3. Do it via a **multi-agent workflow**, then **run the app + test all use cases live** on the connected Samsung, watching logs when opening a video / live stream.
4. Mid-session: **"two videos play — one in front, one in the background"** when casting a live stream then stopping.
5. **Casting a live stream shows the cast icon on the TV but never plays.**
6. Make live streams **actually cast** to the TV — willing to pay; chose the **custom Cast receiver** route ($5 paid).

---

## 2. What shipped and is VERIFIED on-device ✅

### 2a. Skip bug (the reported "+10s → 0:10")
- **Root cause:** `flutter_chrome_cast` 1.4.6's Android bridge
  (`GoogleCastSeekOptionsBuilder.fromMap`) **ignores the `relative` flag** and always
  issues an absolute `setPosition`. So `seekBy(+10s)` seeked to absolute 0:10.
- **Fix** (`lib/services/cast_service.dart` → `seekBy`): read the synchronous
  `GoogleCastRemoteMediaClient.instance.playerPosition`, add the delta, clamp to
  `[0, duration]`, issue an **absolute** seek. Local `better_player` skip was already
  relative and untouched.
- **Verified:** local player position went **00:56 → 01:07** on tapping +10 (relative,
  not a reset).

### 2b. Material 3 dark-first UI overhaul
Full redesign — see `docs/ui-redesign-spec.md` (authoritative). Highlights:
- `lib/app_theme.dart`: dark-first M3 theme, red brand kept as an **accent** (AppBar,
  FilledButton, active segment, progress bar, favorite heart, LIVE badge). Light theme
  defined but not surfaced. `main.dart` → `themeMode: ThemeMode.dark`.
- `lib/screens/home_screen.dart` rebuilt: removed the fake "HD Quality" status pill, the
  PLAYER form tab, the `TabController`/`SingleTickerProviderStateMixin`, and the full-red
  scaffold. New: **16:9 player stage**, `SegmentedButton` (History/Favorites) over an
  `IndexedStack`, **FAB → Add-URL bottom sheet** (Title, URL + Paste, Advanced ▸
  User-Agent, PLAY), **swipe-to-delete + Undo**, Clear-History confirm dialog,
  pull-to-refresh.
- `lib/widgets/video_player_view.dart`: real controls enabled — `aspectRatio: 16/9`,
  fullscreen (`autoDetectFullscreenDeviceOrientation`), ±10s skips, mute, playback speed,
  overflow; branded red spinner + "Loading…"; error box gains an **Edit URL** action.
- `lib/widgets/history_tile.dart`: themed surfaces, relative-time ("2h ago"), single
  labeled favorite heart, `Dismissible` swipe-delete, screen-reader parity via
  `customSemanticsActions` (Delete / favorite).
- `lib/widgets/cast_mini_controller.dart`: compact + scroll-safe, tooltips + 48dp targets,
  **LIVE badge** (when duration is null), labeled volume.
- `lib/widgets/cast_button.dart`, `lib/screens/web_player_screen.dart`: a11y + theme
  polish. `privacy_policy_screen.dart` left as-is (self-contained light page, covered by a
  widget test).
- **Verified on device:** home, idle poster, VOD DRM playback + controls, live HLS
  playback, Add-URL sheet, favorite toggle + Favorites tab, swipe-delete + **Undo restores
  the item**, full accessibility tree (labels + 48dp). No crashes/ANRs.

### 2c. "Two videos playing" (double-playback) bug
- **Root cause:** the redesign wrapped the player stage in an `AnimatedSwitcher`. It keeps
  the **outgoing** `VideoPlayerView` mounted during the fade, and with
  `autoDispose: false` an interrupted/overlapping transition (cast connect churn) **orphans
  a `better_player` controller that keeps decoding audio in the background** — confirmed by
  a `getAbsolutePosition` RangeError flood while the cast UI was foregrounded.
- **Fix** (`home_screen.dart` → `_playerStage`): removed the `AnimatedSwitcher` (swaps now
  unmount+dispose in the same frame), and the local player is gated on
  `castState.isConnected` (torn down the instant a session starts *connecting*), with a
  "Connecting to TV…" placeholder. `cast_service.dart` `_onSessionChanged` tightened to only
  react to drops of an *established* session.
- **Verified:** after casting then stopping, `dumpsys audio` showed **exactly one** media
  `AudioTrack` for the app and the zombie-poll count was **0**.

### 2d. Honest cast-failure detection (no blank-TV "casting")
- **Problem the user hit:** casting a live stream connected but the TV showed the default
  receiver's idle splash; the app said "casting."
- **Fix** (`cast_service.dart`): after `loadMedia`, `_awaitPlaybackStarted` waits for the
  receiver to actually reach **`playing`** (buffering/paused do NOT count — that's the
  stuck-splash state). If it errors or never plays within ~15s, `_endSessionQuietly` ends
  the session (TV returns home) and an `error` state carries a plain-language message; the
  UI falls back to local playback. Also added `passiveDisconnects` notifier + `_endingByUser`
  guard so a "Cast disconnected." snackbar fires only on genuine passive drops.
- **Verified:** live stream → detected → session ended (`onDisconnected: SUCCESS`) → fell
  back to phone with the message. **DRM VOD → reached `playing` → real cast** (see below).

### 2e. DRM VOD casting CONFIRMED on real hardware 🎉
Previously only desktop-validated. On the Mi TV, casting the ClearKey DASH series went
`BUFFERING → PLAYING` (receiver loaded `http://<phone>:<port>/manifest.mpd` from the
on-device decrypt proxy, 1920×1080, audio+subtitle tracks). The decrypted series **played
on the TV**. The stricter `playing` check correctly passes this and fails live HEVC.

**Test status:** `flutter analyze lib test tool` clean; `flutter test` = **48/48 pass**.

---

## 3. Live-stream casting — diagnosis (the crux)

The live channels (beIN / nazika) were probed by pulling a fresh URL + User-Agent from the
app DB, fetching the playlist, decrypting a segment, and running `ffprobe`:

- **Container/transport:** HLS, MPEG-TS segments served as obfuscated `…/NNN.php`.
- **Encryption:** `#EXT-X-KEY:METHOD=AES-128` — the key is TheoPlayer's **public** Big Buck
  Bunny demo key (`cdn.theoplayer.com/.../big_buck_bunny_encrypted/…key`). (Not CENC.)
- **Access:** UA-gated (needs a desktop-Chrome User-Agent).
- **Codec (decisive):** **`hevc` (H.265)**, 1920×1078, + `aac` audio.

**Why it can't cast to the default receiver:** the default/styled receiver (`CC1AD845`) has
**no HEVC decoder**. The proxy can solve UA + AES-128 (delivery), but delivery isn't the
problem — the receiver's **decoder** is. Only a **custom receiver** can use the Mi TV's
hardware HEVC decoder. Custom receivers require a one-time **$5** Google Cast dev
registration. (Your H.264 DRM series cast fine precisely because they're H.264.)

---

## 4. Custom-receiver work — IN PROGRESS 🚧

The user paid the $5 and chose to build native live casting.

### Done
- **Custom CAF receiver** written: `cast_receiver/index.html` (+ `cast_receiver/README.md`).
  It uses `caf_receiver/v3`, logs an on-screen debug overlay, and — critically — probes and
  displays the TV's HEVC support (`canPlay hvc1(fMP4)`, `MSE hvc1`).
- **Hosted** on GitHub Pages via an isolated `gh-pages` branch (pushed with `gh` auth; Pages
  enabled from `gh-pages`/root). Live + serving `text/html`:
  **`https://yossefebrahim.github.io/url-video-player/index.html`**
- **Cast console:**
  - Application registered → **App ID `7B6F0F4A`** (name "VP", Custom Receiver).
  - Device registered → serial `55054C06100000167` ("My Mi TV") → **Ready For Testing**.
- **App wired:** `lib/services/cast_service.dart` → `defaultReceiverAppId = '7B6F0F4A'`
  (kept `styledMediaReceiverAppId = 'CC1AD845'` for reference). Rebuilt + installed.
- Verified the app now discovers with filter criteria including `7B6F0F4A`, and it
  "Connected to device. rejoinedApp: true".

### ⚠️ Open item the user still had to confirm
The **Receiver Application URL in the console was registered wrong** — the user entered the
repo link `https://github.com/yossefebrahim/url-video-player/index.html` (renders GitHub's
site, not the raw page). It must be updated to the **Pages URL**:
`https://yossefebrahim.github.io/url-video-player/index.html`
(Console → Applications → VP → Edit → Receiver Application URL → Update.)
At the point of handoff, the user had just replied "word" (URL updated / TV on) and the
first launch of the custom receiver was being attempted.

### The go/no-go gate (do this next)
Cast once to launch the receiver on the TV and **read the overlay's HEVC lines off the TV**
(I can't screen-grab the TV over adb):
```
canPlay hvc1(fMP4): ...
MSE hvc1: ...
```
- **`probably`/`true`** → the TV decodes HEVC over Cast → proceed to build the proxy.
- **empty/`false`** → the TV's Cast receiver can't do HEVC → **stop** (no proxy work wasted);
  fall back to Smart View for live.

---

## 5. Remaining work (only if HEVC is confirmed)

**Build the live-HLS proxy** (extend `lib/services/cast_proxy_server.dart`, which already
does CENC-DASH):
1. Fetch the `.json` **media playlist** with the User-Agent.
2. Fetch the **AES-128 key** (public theoplayer URL) with the UA.
3. **Decrypt** each TS segment phone-side (AES-128-CBC, IV from the playlist) OR rewrite the
   `#EXT-X-KEY` URI to a phone-served key.
4. Rewrite segment URLs to the phone proxy; **re-poll the rolling live playlist**
   (MEDIA-SEQUENCE advances — it's live, not VOD).
5. Serve to the receiver. If Shaka in the receiver won't transmux **HEVC-in-TS**, the harder
   fallback is remuxing TS→fMP4 (hvc1) on the phone before serving.
6. `CastService._prepareMedia` already branches on stream type — add the live-HLS branch to
   start the proxy and hand the receiver the phone URL.

Then: build/install, cast a live channel, confirm HEVC playback on the Mi TV.

---

## 6. Files changed this session

**Modified (UI + fixes):** `lib/main.dart`, `lib/app_theme.dart`,
`lib/screens/home_screen.dart`, `lib/screens/web_player_screen.dart`,
`lib/widgets/video_player_view.dart`, `lib/widgets/history_tile.dart`,
`lib/widgets/cast_mini_controller.dart`, `lib/widgets/cast_button.dart`,
`lib/services/cast_service.dart` (skip fix, honest-failure detection, passiveDisconnects,
custom App ID).

**New:** `docs/ui-redesign-spec.md`, `cast_receiver/index.html`, `cast_receiver/README.md`,
`docs/handoffs/2026-07-06-ui-overhaul-and-cast.md` (this file).

**Pre-existing uncommitted (prior CENC-proxy session, untouched here):**
`lib/services/cast_proxy_server.dart`, `lib/services/cenc_decryptor.dart`,
`lib/services/clear_key.dart`, `lib/services/cast_media_mapper.dart`, related tests/fixtures.

> Note: nothing has been committed to `main` — all app changes are in the working tree. The
> only thing pushed to GitHub is the `gh-pages` branch (receiver hosting).

---

## 7. Load-bearing facts / gotchas for the next session

- `flutter_chrome_cast` 1.4.6 **drops the `relative` seek flag** (Android) — always compute
  absolute seeks yourself.
- The player uses `autoDispose: false` + manual teardown; **never** wrap it in an
  `AnimatedSwitcher` or anything that delays disposal → orphaned controller = double audio.
- `better_player_plus` floods **`getAbsolutePosition` RangeError** on these live HLS streams
  (bogus program-date-time → Int64 overflow). Non-fatal, library-internal, pre-existing;
  playback is unaffected. Don't mistake it for a bug we introduced.
- Custom receiver `7B6F0F4A` is **unpublished** → only launches on the **registered** Mi TV.
  Other devices won't launch it until it's published (review required).
- Cast receiver URLs must be **HTTPS** and serve `text/html` — `github.com/...` and
  `raw.githubusercontent.com` do NOT work; **GitHub Pages** (`*.github.io`) does.
- On-device test recipe: `ANDROID_SERIAL=192.168.9.2:45349`; launch with
  `adb shell monkey -p info.t4w.vp -c android.intent.category.LAUNCHER 1`; UI via
  `adb shell uiautomator dump` + `adb shell input tap`; count concurrent players with
  `adb shell dumpsys audio` (look for `state:started ... USAGE_MEDIA` for uid of info.t4w.vp).
