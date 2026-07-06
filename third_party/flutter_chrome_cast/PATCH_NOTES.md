# Local fork of flutter_chrome_cast 1.4.6

This is a vendored copy of `flutter_chrome_cast` 1.4.6 with one behavioural fix.
It is wired into the app via a `dependency_overrides` path entry in the app's
`pubspec.yaml`.

## Why we forked

On the test device (Samsung SM-A346E → Xiaomi Mi TV `MiTV-MOOR2`), casting always
failed with `TimeoutException: Cast connection timed out`, with **any** receiver
(the custom `7B6F0F4A` and the default `CC1AD845`).

Root cause, from `adb logcat`:

```
CastMediaRouteProvider: onCreateRouteController: c80972…         ← real Cast route exists
MediaRouter: Selecting route: UserRouteInfo{ name=TV … ROUTE_TYPE_USER }   ← plugin picked the WRONG route
… 15s later …
flutter : CastService.connectAndCast failed: TimeoutException: Cast connection timed out
```

The TV is advertised by **two** `MediaRouter` routes carrying the same
`CastDevice` bundle: the genuine Cast route from `CastMediaRouteProvider`, and a
phantom `ROUTE_TYPE_USER` route (Samsung Smart View / a lingering remote-display
session). Upstream `DiscoveryManagerMethodChannel.selectRoute` did:

```kotlin
val selectedRoute = routes?.find { CastDevice.getFromBundle(it.extras)?.deviceId == id }
```

`find` returns the *first* match. When the phantom user route sorts first,
`router.selectRoute(userRoute)` never starts a CAF session (`onSessionStarted`
never fires), so the plugin's `connectionState` stays `disconnected` and the
sender times out.

## The fix

`selectRoute` now collects **all** routes matching the device id and prefers a
genuine Cast route — one that supports the Cast control category for the current
receiver app id, then remote-playback — before falling back to the first match:

- `DiscoveryManagerMethodChannel.kt` — `selectRoute` rewritten (+ a small
  `supportedTrait()` log helper).
- `CastContextMethodChannel.kt` — stores the receiver app id in a
  `companion object { var appId }` so `selectRoute` can build the exact
  `CastMediaControlIntent.categoryForCast(appId)` category.

Nothing else is changed. To re-pull upstream, re-copy the package and re-apply
these two edits.
