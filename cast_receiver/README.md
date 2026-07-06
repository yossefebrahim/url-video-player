# VP Custom Cast Receiver (live HEVC)

A minimal CAF (Cast Application Framework) receiver that plays the stream the
phone proxy hands it, using **the TV's own hardware HEVC decoder** — which the
default Google receiver can't do. It shows an on-screen debug overlay (device
codec support + player state + errors) so we can diagnose right on the TV.

## Why this exists
The live channels are HEVC (H.265). The default receiver (`CC1AD845`) has no HEVC
decoder, so it connects but shows a blank splash. A **custom** receiver can use
the Google TV's hardware HEVC decoder — but a custom receiver requires the
one-time $5 Google Cast developer registration + hosting this page over HTTPS.

## Step 1 — host `index.html` over HTTPS (free)

Cast requires the receiver to be an **HTTPS** URL. Easiest free option:

### GitHub Pages
1. Create a new GitHub repo (public), e.g. `vp-cast-receiver`.
2. Upload `index.html` from this folder to the repo root.
3. Repo → **Settings → Pages → Build and deployment → Source: Deploy from a
   branch**, Branch: `main` / `/root`, Save.
4. Wait ~1 min. Your receiver URL is:
   `https://<your-username>.github.io/vp-cast-receiver/index.html`
5. Open that URL in a browser — you should see a black page with
   "VP receiver booting…" in the corner. That confirms it's live.

(Any HTTPS static host works — Netlify, Cloudflare Pages, Firebase Hosting, etc.
Just note the final `https://…/index.html` URL.)

## Step 2 — register the Application (get the App ID)

In the **Google Cast SDK Developer Console** (`cast.google.com/publish`):
1. **Applications → ADD NEW APPLICATION → Custom Receiver**.
2. **Name:** `VP` (anything).
3. **Receiver Application URL:** the HTTPS URL from Step 1.
4. Leave the rest default → **Save**.
5. Copy the **Application ID** (looks like `A1B2C3D4`). Send it to me — I plug it
   into the app (`CastService.defaultReceiverAppId`).

## Step 3 — register your TV as a test device (if not done)

**Cast Receiver Devices → ADD NEW DEVICE →** paste the TV's **serial number**
(Google Home app → your Mi TV → ⚙️ → Device information → Serial number). Reboot
the TV. Authorization takes ~15 min to propagate.

## Step 4 — I wire it up

I set the app's receiver id to your App ID and build the live-HLS proxy (fetch
with the User-Agent, decrypt AES-128, re-serve to the receiver). Then we cast a
live channel: the on-screen overlay will show whether the TV decodes HEVC and,
if so, the stream plays.

> The overlay lines to watch first: `canPlay hvc1(fMP4)` and `MSE hvc1`. If those
> come back **empty / false**, the TV's receiver can't do HEVC and no amount of
> proxying will help — we'd stop there. If they say `probably`/`true`, we're on.
