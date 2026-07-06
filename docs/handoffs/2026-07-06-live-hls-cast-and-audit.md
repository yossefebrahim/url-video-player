# Session handoff — live-HLS casting, the cast-connect blocker, and the lifecycle audit

**Date:** 2026-07-06 (continuation of `2026-07-06-ui-overhaul-and-cast.md`)
**Device under test:** Samsung SM-A346E (adb-over-Wi-Fi; the port randomises on
reconnect — rediscover with `dns-sd -L adb-RKCW700B45H-2QzLkT _adb-tls-connect._tcp local.`)
**Cast target:** Xiaomi Mi TV `MiTV-MOOR2` (custom receiver App ID `7B6F0F4A`)

This session picked up the prior handoff's Phase-2 item — actually casting the
live HEVC channels — built and validated the whole phone-side pipeline, then
diagnosed why on-device casting could not connect at all, fixed that, and ran a
full video-player + cast lifecycle audit with fixes.

> **Companion doc:** the focused, executable procedure for finishing the cast
> route fix lives in [`docs/cast-route-fix-plan.md`](../cast-route-fix-plan.md)
> — build/deploy steps, the on-device verification gates, and the decision tree.
> This hand-off is the surrounding context; that plan is the step-by-step. If you
> are an autonomous agent resuming the cast work, read §0 here, then follow the
> plan, and see §7 below for how to run without getting locked.

---

## 1. Live-HLS cast pipeline — BUILT and host-VALIDATED ✅

The remaining Phase-2 work from the prior handoff (§5) is implemented.

- **`lib/services/hls_rewriter.dart` (new):** pure, unit-tested HLS playlist
  rewriter. Rewrites master + media playlists so every URL points back at the
  phone proxy; **terminates AES-128 on the phone** (drops `#EXT-X-KEY`, attaches
  the key URI + IV to each segment ref; derives the per-segment IV from
  `MEDIA-SEQUENCE` when no explicit `IV=`); strips the bogus
  `#EXT-X-PROGRAM-DATE-TIME` these channels carry; handles `#EXT-X-MAP`,
  `#EXT-X-MEDIA`, I-frame, and master-vs-media detection.
- **`lib/services/cast_proxy_server.dart` (rewritten):** an abstract `CastProxy`
  base (LAN bind, CORS, upstream fetch with redirect resolution, `POST /beacon`
  telemetry) with two concrete proxies — the existing `CastProxyServer`
  (ClearKey-CENC DASH decrypt) and the new **`HlsCastProxy`** (re-fetches the
  rolling live playlist each poll, AES-128-CBC-decrypts TS segments phone-side
  with `pointycastle`, caches keys, serves clear MPEG-TS).
- **`lib/services/cast_service.dart`:** `_prepareMedia` now has a live/UA-gated
  HLS branch that starts `HlsCastProxy`; `_adoptProxy`/`_stopProxy` hold a
  wakelock for the proxy's lifetime; `customData` carries a `beacon` URL.
- **`cast_receiver/index.html`:** POSTs its on-screen log (HEVC capability probe,
  player state, errors) to the phone `/beacon`, and sets `useShakaForHls = true`
  so the receiver's Shaka transmuxer can handle HEVC-in-TS. Hosted on
  **GitHub Pages** (`gh-pages` branch): `https://yossefebrahim.github.io/url-video-player/index.html`.
- **`tool/hls_proxy_validate.dart` (new):** runs `HlsCastProxy` against a real
  channel so `ffprobe`/`ffmpeg` can verify the served stream.

**Host validation (decisive):** ran the proxy against the real nazika channel
(`53_42.json`) with the DB's desktop User-Agent. `ffprobe` through the proxy
read **`hevc` Main, 1920×1078 + `aac`**, and `ffmpeg` decoded a decrypted
segment to frames with **zero errors** — proving the phone side end-to-end (UA
gate solved, playlist rewrite, AES-128 decrypt, live re-poll). The receiver's
job (does the TV *decode* HEVC over Cast) is answered by the `/beacon`
telemetry, which needs a live on-device cast — see §3.

---

## 2. THE on-device blocker: cast connect never establishes (fixed) 🔧

Casting on this rig failed with `TimeoutException: Cast connection timed out`
for **both** the custom receiver `7B6F0F4A` and the default `CC1AD845` — so it
was **not** the receiver-URL registration from the prior handoff, and not HEVC.
It failed *before* `loadMedia`, in `_awaitConnected`.

Root cause (from `logcat`): the Mi TV is advertised by **two** `MediaRouter`
routes carrying the same `CastDevice` bundle — the genuine Cast route from
`CastMediaRouteProvider`, and a phantom `ROUTE_TYPE_USER` route (Samsung Smart
View / a lingering remote-display session). `flutter_chrome_cast` 1.4.6's
`DiscoveryManagerMethodChannel.selectRoute` used `routes.find { … deviceId == id }`
— first match wins — and selected the phantom user route, which never starts a
CAF session, so the plugin's `connectionState` never reached `connected`.

**Fix — vendored plugin fork** (`third_party/flutter_chrome_cast`, wired via
`dependency_overrides` in `pubspec.yaml`; see its `PATCH_NOTES.md`):
`selectRoute` now collects **all** routes matching the device id and prefers a
genuine Cast route (`supportsControlCategory(categoryForCast(appId))`, then
remote-playback) before falling back. `CastContextMethodChannel` stores the
receiver appId in a `companion object` so the category can be built.

**Build gotcha (important):** after adding the `dependency_overrides` path, a
plain `flutter install` reused Gradle's cached plugin build — the patched Kotlin
did not recompile and behaviour was unchanged. You must `flutter clean` (bust
the Gradle/AAR cache) before rebuilding. Confirm the patch is live by grepping
logcat for `DiscoveryManager: selectRoute(<id>): N match(es); chose …`.

The APK builds cleanly with the fork. **Its runtime effect was NOT yet confirmed
on-device** — see §3.

---

> **RESOLVED (2026-07-06, follow-up session):** on-device verification ran. The
> route fix works (Gate A ✓; the phantom route was gone — note the framework's
> `Selecting route: UserRouteInfo` line is normal androidx→platform sync, not
> the failure signature). The remaining connect timeout had a different cause:
> the TV does not report the unpublished custom receiver `7B6F0F4A` as
> available (its route lacks `CATEGORY_CAST/7B6F0F4A`), so CAF ignores the
> selection. Workaround: `CastService.ensureInitialized` now inits with
> `CC1AD845` — and the full cast then **worked end-to-end** (session connected,
> MBC ClearKey DASH PLAYING at 1080p via the phone CENC proxy). The Cast-console
> registration check below is now the only blocker for the custom HEVC receiver.

## 3. What still needs a device (the one open item) ⏳

The on-device confirmation could not be completed because (a) the user picked up
the phone mid-test, and (b) the nazika channel's signed URL is time-limited and
**expired during the session** (`403 Access Denied: Link expired`). When the
device is free and a **fresh** channel URL is in the app:

1. `flutter clean && flutter build apk --debug && adb install -r …` (clean is
   required — see §2 gotcha).
2. Launch + load a live channel:
   `adb shell am start -n info.t4w.vp/info.t4w.vp.view.MainActivity --es url '<u>' --es agent '<ua>'`
3. Cast to the TV (cast icon `adb shell input tap 872 154`, TV row `tap 234 2140`).
4. Confirm the fork works: logcat shows `selectRoute(…): chose TV (remote-playback)`
   and the session reaches `connected` (no 15 s timeout).
5. **Read the go/no-go HEVC verdict from `/beacon`** in logcat
   (`adb logcat -d | grep "\[receiver\]"`): the `canPlay hvc1(fMP4)` / `MSE hvc1`
   lines and whether the receiver reaches `PLAYING`. `probably`/`true` + `PLAYING`
   → live HEVC casting works; otherwise the honest-failure path falls back to the
   phone (that path is intact and tested).

Also still open from the prior handoff: verify the **Cast console Receiver
Application URL** for `7B6F0F4A` is the Pages URL
(`https://yossefebrahim.github.io/url-video-player/index.html`), not the
`github.com/...` repo link. (Only matters once connect succeeds.)

---

## 4. Lifecycle audit + fixes ✅

Ran an 8-dimension multi-agent audit of the player + cast lifecycle with 2-lens
adversarial verification — full report in
[`2026-07-06-lifecycle-audit.md`](2026-07-06-lifecycle-audit.md). 24 findings
survived. **All 5 P1, 6/8 P2, and 3/7 P3 were fixed this session** (see that
report's status header for the exact list and the deferred items). Highlights:

- **SSRF relay (P1):** `HlsCastProxy` now only fetches hosts it referenced while
  rewriting a real upstream playlist (a per-session allowlist), rejecting
  `?u=`/`?k=` that decode to `169.254.169.254`, the router, etc. Re-validated
  live: internal host → 403.
- **Proxy/wakelock leaks (P1×2):** `connectAndCast` tears the proxy down on the
  throw path and at entry, so a failed cast can't orphan the HTTP server or pin
  the wakelock.
- **Poisoned memo (P1):** `_ensureParsed` clears its cached future on a failed
  fetch, so one transient hiccup no longer bricks a whole DASH session.
- **Error-page-as-media (P1):** `_fetch` rejects non-2xx (+ a body timeout), so
  an expired-token 403 surfaces as a 502 instead of a 200 "playlist".
- **Ref-counted `WakelockCoordinator` (P2):** the player and cast no longer clear
  each other's wakelock via the global flag.
- **Passive-disconnect autoplay (P2):** a TV drop returns to the idle poster
  instead of silently blasting the video from 0:00 on the phone.

Verified: `flutter analyze` clean, `flutter test` **62/62** (was 48; +14 for the
new proxy/rewriter/hardening coverage).

---

## 5. Files changed this session

**New:** `lib/services/hls_rewriter.dart`, `lib/services/wakelock_coordinator.dart`,
`tool/hls_proxy_validate.dart`, `test/hls_cast_proxy_test.dart`,
`third_party/flutter_chrome_cast/**` (vendored fork + `PATCH_NOTES.md`),
`docs/handoffs/2026-07-06-lifecycle-audit.md`, this file.

**Modified:** `lib/services/cast_proxy_server.dart` (base + CENC + new HLS proxy,
SSRF/statusCode/timeout/beacon/index hardening), `lib/services/cast_service.dart`
(live-HLS branch, proxy lifecycle, wakelock coordinator), `lib/widgets/video_player_view.dart`
(wakelock coordinator + error/finish release), `lib/screens/home_screen.dart`
(passive-disconnect idle), `lib/services/link_parser.dart` (`_sanitizeUrl` — strips
the `407<F>` deep-link prefix; see below), `test/link_parser_test.dart`,
`cast_receiver/index.html` (beacon + Shaka + LAN-only beacon; pushed to `gh-pages`),
`pubspec.yaml` (`dependency_overrides`).

**Late fix — deep-link `407<F>` regression (verified on-device):** the source app
(Ostora) began sending deep links whose decoded URL had a literal `407<F>` prefix
before `https://`, so ExoPlayer rejected series/episodes/lives with
`MalformedURLException: no protocol`. This was NOT the cast fork
(`link_parser.dart`/`deep_link_service.dart`/`android/` were unchanged; the input
changed). `LinkParser._sanitizeUrl` now drops junk before the real `http(s)://`.
Confirmed: the MBC ClearKey series stores a clean URL and plays. Caveats: only
*new* deep links are sanitized (old `407<F>` history rows stay broken until
re-opened); and some live channels have a *separate* `unknown protocol: data`
issue (inline `data:` HLS key `better_player` can't open locally).

> These changes were **committed to `main`** during the session (commits
> `eaf8ae1`, `b520147` — done by the user's tooling, not by an agent; verify with
> `git log`). The `gh-pages` branch (receiver) was also pushed. Confirm state with
> `git status` / `git log --oneline` before assuming an uncommitted working tree.

---

## 6. Gotchas for next time

- **`flutter clean` before rebuilding after any `third_party/flutter_chrome_cast`
  edit** — the path override is otherwise Gradle-cached and your Kotlin change is
  silently ignored.
- adb-over-Wi-Fi **port randomises** on reconnect; rediscover via mDNS (see header).
- The nazika/beIN live URLs are **time-limited** — pull a fresh one from the app
  DB (`adb exec-out run-as info.t4w.vp cat databases/url_video_player.db`,
  `history` table `url`/`user_agent`) right before testing.
- `better_player_plus` still floods `getAbsolutePosition` RangeError on these live
  HLS streams (pre-existing, non-fatal — bogus program-date-time → Int64 overflow).
- Two documented, deferred cast limitations: UA-gated **unencrypted** DASH casts
  to origin and falls back locally after a ~15 s honest error; **byte-range** HLS
  is unsupported (targeted channels use full-file TS segments).

---

## 7. Working autonomously without getting locked (Fable 5)

This hand-off is meant to be resumed by an autonomous agent. To finish the open
cast work (§3) end-to-end without stalling or needing the user mid-flow, follow
these operating rules — the executable procedure with its objective pass/fail
gates is in [`docs/cast-route-fix-plan.md`](../cast-route-fix-plan.md) (§7 there):

- **Don't block on long operations.** Run `flutter clean`/`build`/`install` in the
  background and continue on the completion notification; never foreground-sleep
  for the whole build (the harness blocks long foreground `sleep` anyway). Use a
  single short sleep only for "wait N seconds then read logcat", never an
  open-ended wait.
- **The device may be in use.** Before any `input tap`, take a `screencap` and
  confirm the app is foreground. If the user is actively on the phone, switch to
  **read-only** diagnostics (`logcat -d`, `screencap`, DB pull) and report — do
  not tap over them. (This actually happened this session: taps landed on the
  user's other app.)
- **Decisions are objective, not user-gated.** Every checkpoint (route chosen →
  session connected → receiver playing → honest fallback) is read from
  `logcat`/screenshot. You should not need to ask the user except for a genuine
  scope choice or the browser-only Cast-console step (§3). The only hard external
  dependency is the physical rig (TV + phone + shared Wi-Fi) — if it's absent,
  **stop and report**, don't hang.
- **`flutter clean` is mandatory** after any `third_party/flutter_chrome_cast`
  edit, or the patched Kotlin won't recompile (Gradle caches the path-override
  plugin build). Verify the patch actually ran by grepping logcat for
  `DiscoveryManager: selectRoute(<id>): N match(es)`.
- **Reconnect adb resiliently** (port randomises — mDNS recipe in the header) and
  **pull a fresh, `curl`-checked stream URL** right before casting (URLs expire;
  a stale `403` masquerades as a cast failure).
- **Keep actions reversible.** Prefer `adb install -r` (preserves the history DB);
  reserve `flutter clean`+`flutter install` for when the native fork changed.
  Don't commit or push unless explicitly asked.
- **One change at a time.** If a gate fails, fix only that (usually the build) and
  re-test on a clean base — don't stack speculative edits on an unverified build.
