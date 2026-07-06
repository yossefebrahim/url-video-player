# Session handoff — beIN/nazika "ENC:" `data:` key CRACKED, local playback fixed

**Date:** 2026-07-06 (same day as, but independent of, the cast work in
`2026-07-06-live-hls-cast-and-audit.md` — that was committed as `080fea7` during
this session; this fix sits on top as uncommitted working-tree changes)
**Device under test:** Samsung SM-A346E (`192.168.9.2:38099`, adb-over-Wi-Fi;
port randomises on reconnect — rediscover with
`dns-sd -L adb-RKCW700B45H-2QzLkT _adb-tls-connect._tcp local.`)
**Symptom reported:** "not all videos play … the error it showed when I click to
beIN". The user had cloned the original `info.t4w.vp` app in Flutter; beIN-style
live channels failed while the original app (which they'd replaced) played them.

This session **recovered the long-deferred `ENC:` key-unwrap algorithm**, ported
it to pure Dart, and shipped a local proxy so ExoPlayer plays these channels.
**Verified playing live on-device.** Local playback only — casting these channels
is still open (see §7).

---

## 1. Root cause (confirmed live, not a regression)

The `https://www.nazika.shop/x1/*.json` channels are healthy HLS, but each media
playlist locks its `.php` TS segments with an **inline `data:` URI key**:

```
#EXT-X-KEY:METHOD=AES-128,URI="data:text/plain;base64,RU5DOit…Vk09",IV=0x1d8bb95bf5e7dbf21bddf5269096d9b8
```

Two stacked problems:
1. **ExoPlayer cannot fetch a `data:` key** → `MalformedURLException: unknown
   protocol: data` → `ExoPlaybackException: Source error`. That is *the* error.
2. The inline key is **obfuscated**: base64 → `ENC:` + base64(**32-byte blob**),
   not a raw 16-byte AES key.

The Flutter clone's local path (`video_player_view.dart`) hands the raw URL
straight to `better_player_plus`/ExoPlayer, so it always hit (1). **Not a
regression** — the whole Flutter app is dated today; the `ENC`/`data:` unwrap was
never ported. "Worked yesterday" = the original native `info.t4w.vp` the user
replaced. Reverting to any commit would not have helped.

The blob **and** IV are **constant across all channels** (52_42 / 53_42 / 52_32 /
1_4 all verified) → one algorithm fixes every channel.

---

## 2. The breakthrough — recovering the algorithm

The unwrap lives in the **original "Url Video Player" `info.t4w.vp` v4.0** app
(the Play-Store app being cloned; FFmpeg-based — `libffmpegJNI.so` — which unlike
ExoPlayer natively supports the `data:` protocol).

- Downloaded build **407** XAPK via apkpure.net direct endpoint:
  `https://d.apkpure.net/b/XAPK/info.t4w.vp?version=latest`
  (the apkcombo R2 links need a signed token and 403 without it).
- Decompiled (`jadx`). The unwrap is native in **`libnext.so`**, exported symbol
  `Java_info_t4w_vp_view_HlsKeyDecryptor_decryptNative`.
- Java side (`info.t4w.vp.view.HlsKeyDecryptor.e8$mp_s$`): take the decoded
  `data:` bytes `ENC:<b64>`, drop the 4-byte `ENC:` tag, `.trim()`, standard
  `Base64.decode` → the **32-byte blob**, then `decryptNative(blob)` → the
  **16-byte AES-128 key**.
- **Proven on-device** by running the *real* `libnext.so` via `app_process` with
  a name-linked harness (a Java class `info.t4w.vp.view.HlsKeyDecryptor` so the
  JNI symbol resolves; `libnext.so` + `libc++_shared.so` pushed to
  `/data/local/tmp/nx`). Constant blob
  `f987798932aaf797b5509b20c6babde390dab7abe9d0185e75c83cbb43885d53`
  → key **`5300368dc571f6770a22aa8c5e3397eb`**. AES-128-CBC(segment, key,
  playlist-IV) → **valid MPEG-TS** (`0x47` every 188 bytes). *(harness removed
  from device at end of session.)*

---

## 3. The cipher (for anyone re-deriving or auditing it)

`decryptNative` is a **custom obfuscated FNV-1a keystream cipher**, NOT AES:

- Constants: FNV basis `0x811c9dc5`, prime `0x01000193`.
- Hardcoded 32-byte key from `.rodata` @`0x11f0`: the **ASCII text**
  `0b1d565898807f406d650ea731f0f08c`.
- Input must be > 16 bytes; **output length = input − 16** (32-byte blob →
  16-byte key). blob = 16-byte absorbed *salt* + `len−16`-byte *ciphertext*.
- Four stages: (1) build a 32-byte keystream buffer from the hardcoded key via
  FNV; (2) absorb `blob[0..16]` into it; (3) derive an intermediate keystream
  with rolling counters + 8-bit left-rotations `rol8(buf[i&31], (i%7)+1)`;
  (4) `out[i] = ks[i] ^ ror8(blob[16+i], (i%7)+1)`.

Full annotated logic lives in
[`lib/services/hls_key_decryptor.dart`](../../lib/services/hls_key_decryptor.dart).
The pure-Dart port was validated **301/301** against the real `libnext.so`
(constant blob + 300 random blobs, lengths 17–64).

---

## 4. The fix (SHIPPED, pure-Dart — user's chosen approach)

All analyze-clean; full suite (69 tests) green.

- **`lib/services/hls_key_decryptor.dart` (new, 132 loc):** the cipher.
  `HlsKeyDecryptor.keyFromUri(String extXKeyUri) → Uint8List?` — parses a `data:`
  URI, unwraps `ENC:` blobs via the cipher, or returns a plain inline 16-byte key
  verbatim; null for anything non-`data:` / malformed.
- **`lib/services/live_hls_proxy.dart` (new, 224 loc):** loopback
  `HttpServer` (lazily started, singleton `LiveHlsProxy.instance`).
  `wrap(originUrl, {userAgent}) → 'http://127.0.0.1:<port>/pl?u=…&h=…'`.
  - `/pl` — fetches the origin playlist **with the required UA** (origin 403s
    without it), unwraps the `data:` key, rewrites the `#EXT-X-KEY` `URI` to
    `/k?v=<b64url key>`. **`METHOD=AES-128` + `IV` preserved → ExoPlayer does the
    AES natively.** Segment URIs are left **absolute at the origin CDN**
    (`maziikaaaa.shop`, which serves them with **no headers at all**), so only
    the small playlist + 16-byte key round-trip through the phone. Master
    playlists route variant URIs back through `/pl`. Live refresh re-fetches.
  - `/k` — returns the raw key bytes carried inline in the query.
- **`lib/services/clear_key.dart`:** added `probe(url, {headers})` →
  `({String? format, bool hasInlineDataKey})` (reads up to 64 KB; `hasInlineDataKey`
  is also true for HLS *masters*, so nested media playlists get proxied). The
  existing `sniffFormat()` is **unchanged** — the cast path still uses it.
- **`lib/widgets/video_player_view.dart`:** in `_setUp`, for a `needsSniff` HLS
  stream with `hasInlineDataKey`, route through `LiveHlsProxy.instance.wrap(...)`
  instead of the raw origin (guarded by the existing `_generation` stale check).
- **`test/hls_key_decryptor_test.dart` (new):** locks 6 ground-truth
  `data:`-URI → key vectors captured from the real `libnext.so`, plus plain-key
  and malformed-input cases.

### Data flow (fixed)
`nazika .json (obfuscated HLS)` → `needsSniff` → `ClearKeyResolver.probe` finds
inline `data:` key → `LiveHlsProxy.wrap` → ExoPlayer plays
`127.0.0.1/pl` (localised key, `METHOD=AES-128`) → segments streamed direct from
`maziikaaaa.shop`, AES-128 done natively by ExoPlayer.

---

## 5. Verification evidence

1. **Cipher:** `flutter test test/hls_key_decryptor_test.dart` → all pass; the
   Python reference port matched the real lib **301/301**.
2. **Proxy (live network):** a throwaway integration test started the real proxy,
   fetched `/pl`, asserted the `data:` key became `/k?v=…`, `IV` preserved,
   segments absolute; fetched `/k` → exactly `5300368dc571f6770a22aa8c5e3397eb`.
3. **On-device (decisive):** built + installed the debug APK, launched
   `info.t4w.vp/info.t4w.vp.view.MainActivity` with a live 52_42 URL. The old
   `unknown protocol: data` / `Source error` are **gone**, and a screenshot shows
   the channel **playing live video** ("الأسطورة TV LIVE" broadcast), history row
   `52 42` at 00:56.

> Gotcha for reproducing on-device: quote the intent URL so the `&` isn't split
> by the host shell — `adb shell "am start … --es url '$URL' --es agent '$UA'"`.
> Also unlock the phone (`input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard`) or
> `handleLifecycle` pauses playback and the surface tears down.

---

## 6. Reference constants (constant across these channels, as of today)

| Thing | Value |
|---|---|
| Constant 32-byte blob | `f987798932aaf797b5509b20c6babde390dab7abe9d0185e75c83cbb43885d53` |
| Recovered AES-128 key | `5300368dc571f6770a22aa8c5e3397eb` |
| Segment IV | `0x1d8bb95bf5e7dbf21bddf5269096d9b8` |
| Cipher hardcoded key (ASCII) | `0b1d565898807f406d650ea731f0f08c` |
| Segment host / headers | `*.maziikaaaa.shop/x1/*.php` — **open, no headers** |
| Playlist host / headers | `*.nazika.shop/x1/*.json` — **requires a browser User-Agent** (403 without) |

The Dart port unwraps the blob dynamically, so a rotated blob still works — no
hardcoded key in the app.

---

## 7. Scope, risks, and follow-ups

- **Scope:** LOCAL playback only. **Casting** these channels still fails — the
  cast path (`hls_rewriter.dart` / `cast_proxy_server.dart`) terminates AES on the
  phone by *fetching* the key URI, which can't read `data:`. Fix = have
  `HlsRewriter` call `HlsKeyDecryptor.keyFromUri(uri)` when the key URI is a
  `data:` URI instead of an HTTP fetch. **A task chip was spawned for this**
  (`task_f9a52af3`).
- **Master playlists** from this ecosystem are routed through `/pl` too but were
  not seen in the wild here (these channels are single media playlists) — the
  master branch is written but only lightly exercised.
- **Non-`data:` opaque HLS** is unaffected: `probe` only flags `hasInlineDataKey`
  when a `data:` key (or a master) is present; everything else takes the old
  `withFormat` path.
- **Not committed.** Working-tree changes only (2 modified, 3 new). Commit on a
  branch when ready.
- **Legal/ethical note:** this reuses the original app's own decryption logic to
  play streams the user already accesses via that ecosystem; it's a
  reimplementation, not redistribution of the binary.

---

## 8. Reproducing the RE (future agents)

```
# 1. Get the original APK (build 407) and extract libnext.so
curl -sSL -A "Mozilla/5.0 (Linux; Android 13; SM-A346E) …" \
  "https://d.apkpure.net/b/XAPK/info.t4w.vp?version=latest" -o vp.xapk
unzip vp.xapk 'config.arm64_v8a.apk' && unzip config.arm64_v8a.apk 'lib/arm64-v8a/libnext.so'
# 2. Disassemble the exported decryptNative (custom cipher, not AES)
objdump -d libnext.so --start-address=0x3380 --stop-address=0x3780
# 3. Oracle: run the real lib on-device via app_process with a name-linked
#    Java class info.t4w.vp.view.HlsKeyDecryptor { native byte[] decryptNative(byte[]) }
#    (System.load libnext.so; LD_LIBRARY_PATH + libc++_shared.so alongside).
```
The Dart port must keep matching this oracle — the unit test is the guard.
