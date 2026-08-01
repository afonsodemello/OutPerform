# OutPerform — PWA

A cross-platform (iOS + Android) installable Progressive Web App version of OutPerform.
It runs the same scoring engine as the native app — recovery, strain, sleep, readiness,
stress and the Three-Process cognitive-focus model — entirely in the browser, on-device.

## Files
- `index.html` — app shell + iOS/Android install meta.
- `styles.css` — mobile UI (dark, brand-matched, bottom tab bar).
- `algorithms.js` — the scoring engine, ported from the iOS app's Swift calculators.
- `app.js` — UI, routing, data layer (localStorage), install handling.
- `sw.js` — service worker (offline app shell + installability).
- `manifest.webmanifest` — PWA manifest (name, icons, standalone display).
- `icons/`, `apple-touch-icon.png` — app icons.

## Run locally
A PWA needs to be served over HTTP(S) (service workers don't work from file://):
```bash
cd OutPerformPWA && python3 -m http.server 8000   # open http://localhost:8000
```
Service workers also require **HTTPS in production** (localhost is exempt).

## Install (Add to Home Screen)
- **Android (Chrome):** a built-in "Install app" prompt appears; or menu → Install app / Add to Home screen.
- **iOS (Safari):** Share → **Add to Home Screen**. (iOS only installs PWAs from Safari, and only supports the `apple-touch-icon` + standalone meta — both are included.)

Once installed it launches full-screen with its own icon, works offline (app shell), and behaves like a native app.

## Important: data sources on the web
A PWA runs in the browser, which has hard limits the native app does not:
- **Apple Health (HealthKit) is NOT accessible from a PWA** — there is no web API. This is iOS-native only.
- **Google Health** can be reached from the web via OAuth 2.0, but it needs a **Web** OAuth client (the iOS client ID won't work), plus handling of CORS and Google's restricted-scope verification. This is the intended cross-platform live-data path and is stubbed for now ("coming soon" in the Data tab).

So today the PWA computes scores from **data you enter/import** (Data tab), seeded with realistic sample data so it's fully populated on first launch. The scoring engine is identical to the native app.

## Deploy
Static hosting, same as the marketing site (Cloudflare Pages / Netlify / GitHub Pages).
Could live at e.g. `app.outperform.afonsodemello.com`. Must be served over HTTPS for the
service worker and install to work.
