# Cast route fix — implementation & verification plan

**Status update (2026-07-06, on-device run):** Gate A **PASSED** — the patched
`selectRoute` ran and chose the genuine Cast route (`selectRoute(c80972…): 1
match(es); chose TV (remote-playback)`, followed immediately by
`CastMediaRouteProvider: onCreateRouteController`). The phantom UserRoute was
gone this run (1 match, not 2). Two corrections to this plan's assumptions:

1. The log line `MediaRouter: Selecting route: UserRouteInfo{… ROUTE_TYPE_USER}`
   is **normal androidx→platform sync** and appears even when the correct Cast
   route is selected — do not read it as the phantom-route failure (§1/§7 Gate A
   treat it as a FAIL signature; it isn't one on its own. The real discriminator
   is the presence of the `DiscoveryManager: selectRoute(…)` line and
   `onCreateRouteController` firing at selection time).
2. Gate B still **FAILED** (15 s timeout), but for a *different* root cause than
   route selection: the TV's Cast route does not advertise
   `CATEGORY_CAST/7B6F0F4A` — the TV reports the unpublished custom receiver as
   **unavailable** (Cast-console registration: receiver URL and/or device
   serial). CAF's session-manager callback filters route-selection events on
   that category, so the selection is silently ignored and no session starts.
   Workaround applied in `CastService.ensureInitialized`: init CAF with
   `styledMediaReceiverAppId` (`CC1AD845`, always available). The §10 Cast
   console check is now the *primary* blocker for the custom receiver, not a
   follow-up.

**CONFIRMED (same day, ~14:01):** with `CC1AD845` the full chain passed on the
rig — Gate A ✓ (patched `selectRoute` chose the Cast route), Gate B ✓
(`Connected to device` → `onApplicationConnected: CC1AD845`, no timeout),
Gate C ✓ (receiver `playerState:PLAYING`, 1920×1080, the MBC ClearKey DASH
served clear through the phone CENC proxy; mini-controller showed
"index — On TV"). Remaining work: fix the Cast-console registration for
`7B6F0F4A` (browser-only user step, §10), then flip
`CastService.ensureInitialized` back to `defaultReceiverAppId` to regain HEVC.

**Original status:** fix is written and compiles; **on-device runtime effect not yet confirmed.**
**Audience:** a future autonomous agent (Claude Fable 5) picking this up in a fresh
session. This document is self-contained — you do not need the original chat.

**Related hand-off (read alongside this plan):**
[`docs/handoffs/2026-07-06-live-hls-cast-and-audit.md`](handoffs/2026-07-06-live-hls-cast-and-audit.md)
— the session hand-off that produced this fix. It has the fuller narrative of how
the route bug was found, the live-HLS cast pipeline, the lifecycle audit, and the
same "work autonomously without getting locked" operating notes. This plan is the
focused, executable procedure; that hand-off is the context around it. Other
references are listed in §10.

---

## 0. TL;DR

Casting on the test rig failed with `TimeoutException: Cast connection timed out`
for **every** receiver, because `flutter_chrome_cast` 1.4.6 selected the wrong
Android `MediaRouter` route for the TV. A vendored fork
(`third_party/flutter_chrome_cast`, wired via `dependency_overrides`) fixes the
route selection. The code is done. **What remains is to prove it on hardware**:
build (with a mandatory `flutter clean`), cast, and confirm from `logcat` that
(a) the patched `selectRoute` chose the real Cast route and (b) the session
reaches `connected` without the 15-second timeout.

If you have no TV + phone + shared Wi-Fi available, **stop and report** — this
task cannot be completed without the physical rig. Do not hang waiting.

---

## 1. Background — the bug (self-contained)

The app casts by handing a URL to a Google Cast (CAF) receiver. `CastService`
(`lib/services/cast_service.dart`) drives it: `connectAndCast()` calls
`startSessionWithDevice()` then `_awaitConnected()` (polls the plugin's
`connectionState` for `connected`, 15 s timeout) before loading media.

On the test device (Samsung SM-A346E → Xiaomi Mi TV `MiTV-MOOR2`) the TV is
advertised by **two** `MediaRouter` routes that both carry the same `CastDevice`
bundle:
1. the genuine Cast route from `CastMediaRouteProvider`, and
2. a phantom `ROUTE_TYPE_USER` route (Samsung "Smart View" / a lingering
   remote-display session).

Upstream `DiscoveryManagerMethodChannel.selectRoute(id)` did:

```kotlin
val selectedRoute = routes?.find { CastDevice.getFromBundle(it.extras)?.deviceId == id }
```

`find` returns the **first** match. The phantom user route sorted first, and
`router.selectRoute(userRoute)` **never starts a CAF session** — so
`onSessionStarted` never fires, the plugin's `connectionState` stays
`disconnected`, and `_awaitConnected()` times out. Log signature of the failure:

```
CastMediaRouteProvider: onCreateRouteController: c80972…        ← real Cast route exists
MediaRouter: Selecting route: UserRouteInfo{ name=TV … ROUTE_TYPE_USER }   ← WRONG route chosen
… 15 s later …
flutter : CastService.connectAndCast failed: TimeoutException: Cast connection timed out
```

This is independent of the receiver (it reproduced on both the custom HEVC
receiver `7B6F0F4A` and the default `CC1AD845`) and independent of the live-HLS /
HEVC work.

---

## 2. The fix that is already in place

A **vendored fork of `flutter_chrome_cast` 1.4.6** lives at
`third_party/flutter_chrome_cast/` and is wired into the app via
`dependency_overrides` in `pubspec.yaml`. See its `PATCH_NOTES.md`. Two files
changed vs. the pub.dev release:

- **`android/src/main/kotlin/com/felnanuke/google_cast/DiscoveryManagerMethodChannel.kt`**
  — `selectRoute()` now collects **all** routes matching the device id and
  prefers a genuine Cast route before falling back:
  1. a route that `supportsControlCategory(CastMediaControlIntent.categoryForCast(appId))`,
  2. else one supporting `MediaControlIntent.CATEGORY_REMOTE_PLAYBACK`,
  3. else the first match (old behaviour).
  It logs the choice: `DiscoveryManager: selectRoute(<id>): <N> match(es); chose <name> (<trait>)`.
  A blank/`null` `appId` is coalesced to the default receiver id before calling
  `categoryForCast` (which throws on blank).

- **`android/src/main/kotlin/com/felnanuke/google_cast/CastContextMethodChannel.kt`**
  — stores the receiver `appId` in a `companion object { var appId }` when
  options are set, so `selectRoute` can build the exact Cast control category.

Nothing else is changed; the fork is otherwise byte-identical to 1.4.6, so no
shared Android libraries shift (`pubspec.lock` shows only the plugin's source
moving from pub.dev to the local path).

**It compiles cleanly** (`flutter build apk --debug` succeeds). Its runtime
behaviour on the TV is the only unverified part.

---

## 3. Pre-flight checklist (gather these before touching the device)

Run these read-only checks first. If any fails, resolve or report before proceeding.

| Check | Command | Expected |
|---|---|---|
| Fork is wired | `grep -A2 dependency_overrides pubspec.yaml` | points at `third_party/flutter_chrome_cast` |
| Override resolved | `grep -o 'flutter_chrome_cast[^,]*third_party[^,]*' .flutter-plugins-dependencies` | shows the `third_party` path with `native_build:true` |
| Patch present | `grep -n "match(es); chose" third_party/flutter_chrome_cast/android/src/main/kotlin/com/felnanuke/google_cast/DiscoveryManagerMethodChannel.kt` | matches |
| Tests green | `flutter test` | all pass |
| Analyze clean | `flutter analyze lib test tool` | no issues |

---

## 4. Build & deploy (⚠️ the `flutter clean` gotcha)

**A `dependency_overrides` path swap of a plugin's Android code is cached by
Gradle.** A plain `flutter install`/`flutter build` after editing anything under
`third_party/flutter_chrome_cast/` will silently reuse the old compiled Kotlin —
your change will not take effect. **You must `flutter clean` first** whenever the
vendored native code changed since the last build.

```bash
flutter clean
flutter pub get
flutter build apk --debug        # ~40 s cold; recompiles the vendored Kotlin
```

Then install onto the connected device (see §5 for the device id):

```bash
adb -s <serial> install -r build/app/outputs/flutter-apk/app-debug.apk
```

Use `adb install -r` (not `flutter install`) so the existing history/DB is
**preserved** — `flutter install` uninstalls first and wipes it.

> **For an autonomous agent:** run the build with `run_in_background: true` and
> react to the completion notification instead of blocking for a minute. Do not
> foreground-sleep for the whole build.

---

## 5. Connect to the device (adb-over-Wi-Fi)

The rig uses wireless debugging, and **Android randomizes the adb TCP port on
each reconnect**. If `adb devices` doesn't show the phone, rediscover the port
via mDNS and reconnect:

```bash
# Resolve the current host:port for the phone's wireless-debug service.
dns-sd -L "adb-RKCW700B45H-2QzLkT" _adb-tls-connect._tcp local.
#   → "… can be reached at Android.local.:<PORT>"
adb connect 192.168.9.2:<PORT>
adb devices -l   # confirm SM_A346E / model a34x is listed
```

Set `ANDROID_SERIAL=192.168.9.2:<PORT>` for subsequent commands (or pass `-s`).

- **Phone LAN IP:** `192.168.9.2` · **mDNS adb service:** `adb-RKCW700B45H-2QzLkT`
- **TV:** Xiaomi Mi TV, friendly name `TV`, model `MiTV-MOOR2`,
  Cast device id `c80972ae7319559bdeb853e20c373161`
- **App package:** `info.t4w.vp` · **receiver IDs:** custom HEVC `7B6F0F4A`
  (current default in `CastService.defaultReceiverAppId`), plain `CC1AD845`.

---

## 6. Get a castable, non-expired stream

Channel/series URLs are **time-limited** — pull a fresh one from the app DB right
before testing, don't reuse an old one:

```bash
adb -s <serial> exec-out run-as info.t4w.vp cat databases/url_video_player.db > /tmp/app.db
sqlite3 /tmp/app.db "SELECT rowid, url, user_agent FROM history;"
```

Notes on the stored URLs:
- Some rows have a literal **`407<F>` prefix** before `https://` — that's the
  (now-sanitized) Ostora deep-link artifact. Strip everything before `https://`
  to get the real URL for a freshness check.
- Verify freshness before wasting a cast: `curl -s -o /dev/null -w "%{http_code}\n" -A "<ua>" "<clean-url>"` → expect `200`.

**Best test stream = the MBC series** (`mbcvod-enc.edgenextcdn.net/.../index.mpd###<k>:<kid>`):
it is **H.264 + ClearKey CENC DASH**, which the phone-side CENC proxy already
serves to the default receiver. It exercises the connect path **without** needing
the TV to decode HEVC, so it isolates the route fix. Only move to a live HEVC
channel once the route fix is confirmed.

Load a stream and auto-play via the intent-extra path (the app's activity-alias
accepts `url`/`agent` extras; the URL sanitizer strips any `407<F>` prefix):

```bash
adb -s <serial> shell am start -n info.t4w.vp/info.t4w.vp.view.MainActivity \
  --es url "'<clean-or-407-prefixed-url>'" --es agent "'<ua>'"
```

Confirm it plays locally first (a decoder runs, no error box) — that rules out a
stream problem before you blame casting.

---

## 7. Verification protocol (the actual test)

Drive the UI and read the verdict from `logcat`. Clear the log immediately before
casting so the capture is clean.

```bash
adb -s <serial> logcat -c
# Open the cast picker (top-right cast icon) — portrait coords ≈ x=872 y=154.
adb -s <serial> shell input tap 872 154
# Verify the "Cast to TV / MiTV-MOOR2" sheet is up before tapping the row:
adb -s <serial> exec-out screencap -p > /tmp/picker.png   # inspect it
# Tap the TV row — coords ≈ x=234 y=2140 (verify from the screenshot; don't
# blind-tap if the layout differs).
adb -s <serial> shell input tap 234 2140
```

Wait ~20 s, then read the gates:

```bash
adb -s <serial> logcat -d | grep -iE \
  "selectRoute\(|Selecting route|onSessionStarted|Connected to device|rejoinedApp|CastService|\[receiver\]|TimeoutException|castingMedia"
```

### Gate A — did the patched route selection run and pick the Cast route? (the core fix)
- **PASS:** a line `DiscoveryManager: selectRoute(c80972…): 2 match(es); chose TV (remote-playback)`
  (or `… chose … (generic)` when only the Cast route is present).
- **FAIL — patch didn't run:** you only see the framework line
  `MediaRouter: Selecting route: UserRouteInfo{ … ROUTE_TYPE_USER }` and **no**
  `DiscoveryManager: selectRoute(…)` line. → the vendored Kotlin wasn't compiled
  in. Redo §4 with `flutter clean` (this is the #1 failure mode).

### Gate B — did the CAF session establish? (no timeout)
- **PASS:** the app UI leaves "Connecting to TV…" and shows either the cast
  mini-controller or the honest-failure fallback; **no**
  `TimeoutException: Cast connection timed out` in the log.
- **FAIL:** `flutter : CastService.connectAndCast failed: TimeoutException` after
  ~15 s. → route selection still wrong, or a stale session. Try: fully end any
  session (`disconnect` from the app / power-cycle the TV's cast) and retry once;
  if it persists, capture the full `selectRoute`/`MediaRouter` lines and report.

### Gate C — did the receiver load & play? (only meaningful once B passes)
- Read the receiver telemetry the phone proxy collected:
  `adb -s <serial> logcat -d | grep "\[receiver\]"` → look for
  `canPlay hvc1(fMP4): …`, `MSE hvc1: …`, `state=PLAYING`, or `ERROR code=…`.
- For the **H.264 series** you expect it to reach `PLAYING` (real cast) — this is
  the success proof for the route fix.
- For a **live HEVC** channel: `canPlay hvc1(fMP4)` = `probably`/`true` **and**
  `state=PLAYING` → live HEVC casting works. Empty/`false` or an `ERROR` → the
  TV's receiver can't decode HEVC over Cast; the app's honest-failure path ends
  the session and falls back to the phone (expected, not a bug).

### Gate D — honest-failure fallback still intact
- If casting fails at load/playback (not connect), the app must return to local
  playback with a plain-language message, not a stuck "casting to a blank TV".
  Confirm the UI fell back and a single media `AudioTrack` remains
  (`adb -s <serial> shell dumpsys audio | grep -i "state:started"` for uid of
  `info.t4w.vp` → exactly one).

---

## 8. Outcome decision tree

- **A ✓, B ✓, C ✓ (series reaches PLAYING):** the route fix works. Update
  `docs/handoffs/2026-07-06-live-hls-cast-and-audit.md` §3 to "confirmed", mark
  the on-device task done, then (optionally) proceed to a live HEVC channel to
  answer the HEVC go/no-go via Gate C.
- **A ✓, B ✓, C ✗ (HEVC only):** connect is fixed; HEVC decode is the receiver's
  limit. Confirm the custom receiver URL is registered correctly (see §10) and
  read the `canPlay hvc1` verdict — that's the real go/no-go for live HEVC.
- **A ✗ (no `selectRoute` log):** the vendored Kotlin isn't compiled in. Re-run
  §4 **with `flutter clean`**. This is almost always the cause.
- **B ✗ despite A ✓:** the chosen route still doesn't start a session — capture
  the route dump (`adb shell dumpsys media_router`) and the full `selectRoute`
  match list, and report; may need to also skip routes whose
  `connectionState`/provider isn't the Cast provider.

---

## 9. Operating notes for an autonomous agent (so you don't get "locked")

These make the plan runnable end-to-end by a Fable 5 agent without stalling or
needing the user mid-flow:

- **Never block on long operations.** Run `flutter build`/`install` with
  `run_in_background: true` and continue when the completion notification
  arrives. Do not foreground-`sleep` for the whole build (and note foreground
  `sleep` is blocked by the harness anyway).
- **Poll, don't hang.** For "wait ~20 s then read logcat", a single short sleep
  is fine; never wait on an indefinite condition. If a step can't make progress,
  record why and move on or stop — don't spin.
- **Respect the device owner.** Before driving input, take a `screencap` and
  check the app is foreground. If the user is actively using the phone (a
  different app, the recents view), **switch to read-only diagnostics only**
  (`logcat -d`, `screencap`, DB pull) and report — do not tap over them.
- **Every gate is objective.** Success/failure at each step is decided from
  `logcat`/screenshot, not from the user. You should not need `AskUserQuestion`
  except for a genuine scope decision. The only hard external dependency is the
  physical rig (TV + phone + shared Wi-Fi); if it's absent, stop and say so.
- **Verify UI state before tapping.** Layouts/coords can shift; dump
  `uiautomator`/`screencap` and confirm the target element before `input tap`,
  rather than blind-tapping fixed coordinates.
- **Reconnect adb resiliently.** If a command reports no device, run the mDNS
  rediscovery in §5 and retry once before concluding the rig is unavailable.
- **Streams expire.** Always pull a fresh URL (§6) and `curl`-check it returns
  `200` immediately before casting; a stale `403` looks like a cast failure but
  isn't.
- **Keep actions idempotent & reversible.** Prefer `adb install -r` (preserves
  DB). Don't `flutter clean`+`flutter install` unless the native fork changed
  (it wipes history). Don't commit or push unless explicitly asked.
- **One change at a time.** If Gate A fails, fix only the build/compile issue and
  re-test; don't stack speculative code changes on an unverified base.

---

## 10. Follow-ups & related items

- **Cast console receiver URL (custom HEVC receiver `7B6F0F4A`):** verify in the
  Google Cast Developer Console that the *Receiver Application URL* is the Pages
  URL `https://yossefebrahim.github.io/url-video-player/index.html` (serves
  `text/html`), **not** the `github.com/...` repo link. This is a manual,
  browser-only step the user must do — only matters once Gate B passes and you're
  chasing the custom receiver.
- **Upstream the fix:** consider filing an issue / PR against
  `flutter_chrome_cast` with the `selectRoute` route-preference change so the
  fork can eventually be dropped. Until then, keep the fork and its
  `PATCH_NOTES.md` in sync if the plugin is upgraded.
- **Unrelated known issue (do not conflate):** some live channels fail *local*
  playback with `unknown protocol: data` (their HLS playlist embeds a `data:`
  inline key `better_player` can't open). That is a separate, pre-existing
  problem from the route fix — track it independently.
- **Reference docs:** `third_party/flutter_chrome_cast/PATCH_NOTES.md` (the
  fork), `docs/cast-to-tv-spec.md` (authoritative Cast design/limits),
  `docs/handoffs/2026-07-06-live-hls-cast-and-audit.md` (how we got here).

---

## 11. Rollback (if the fork must be removed)

If the fork ever needs to be backed out (e.g. it regresses something or a fixed
upstream is adopted):

1. Remove the `dependency_overrides: flutter_chrome_cast:` block from
   `pubspec.yaml`.
2. `rm -rf third_party/flutter_chrome_cast` (and the folder if now empty).
3. `flutter clean && flutter pub get` (re-resolves to pub.dev
   `flutter_chrome_cast: ^1.4.6`).
4. `flutter build apk --debug` and reinstall.

This restores stock casting (with the original route-selection bug on this
device). `better_player_plus` local playback is unaffected either way — the fork
only touches the Cast path.
