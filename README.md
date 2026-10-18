# OutPerform

A recovery / strain / sleep / readiness app for iOS that analyses your health
data entirely on-device, using published sports-science methods (RMSSD/DFA-α1
HRV, Banister TRIMP, Gellish max-HR, Foster monotony, ACWR, Astrand VO₂, ODI).

Built with SwiftUI + SwiftData + Swift Charts, targeting iOS 26.5. No backend,
no subscription — everything runs locally.

## What it does

| Feature | Where |
|---|---|
| Recovery score (HRV/RMSSD, RHR, resp rate, sleep, skin-temp & SpO₂ penalties, DFA-α1) | `Algorithms/RecoveryCalculator.swift`, `HRVAnalysis.swift` |
| Strain 0–21 (TRIMP, HR zones, muscular-load, **ACWR**, **monotony**) | `Algorithms/StrainCalculator.swift` |
| Sleep metrics + performance + **apnea screening (ODI)** | `Algorithms/SleepCalculator.swift`, `SleepApneaScreener.swift` |
| Sleep need (dynamic model), bedtime planner, **chronotype** | `Algorithms/SleepNeedCalculator.swift` |
| Stress monitor + breathwork (physiological sigh, box, cyclic) | `Algorithms/StressCalculator.swift`, `Views/BreathworkView.swift` |
| Health monitor (5 vitals vs personal baseline) + illness heuristic | `Algorithms/HealthMonitor.swift` |
| VO₂ max (HealthKit value or HR-ratio estimate) | `Algorithms/VO2MaxCalculator.swift` |
| Unified **Readiness** score, 7/30/90-day trends, daily check-in | `Algorithms/ReadinessCalculator.swift`, `Views/TrendsView.swift` |

Items in **bold** are extra metrics beyond the basics.

## Data sources (both supported)

The app reads through a single `HealthDataProvider` protocol
(`Health/HealthDataProvider.swift`), so the source is pluggable. Pick one in
onboarding or Settings:

- **Apple Health** — `HealthKitProvider` (the default). Reads HR, HRV (SDNN),
  RHR, respiratory rate, SpO₂, sleeping wrist temperature, sleep stages, workouts
  and VO₂ max directly from HealthKit. For HRV it reads the **beat-to-beat
  heartbeat series** (`HKSeriesType.heartbeat()` + `HKHeartbeatSeriesQuery`) when
  an Apple Watch recorded it, giving a true RMSSD and DFA-α1; otherwise it falls
  back to the SDNN value your wearable wrote, so you always get a recovery score.
  Requires the HealthKit capability (and a device with real Health data).
- **Google Health** — `GoogleHealthProvider`. Talks to the **Google Health API**
  (`health.googleapis.com/v4`, the platform replacing the Fitbit Web API). Auth is
  Google OAuth 2.0 (PKCE via `ASWebAuthenticationSession`, `access_type=offline`);
  data is read from the `dataPoints` REST endpoints. Scopes:
  `googlehealth.health_metrics_and_measurements.readonly`,
  `…activity_and_fitness.readonly`, `…sleep.readonly`, `…profile.readonly`.
  Data types: `heart-rate`, `daily-heart-rate-variability`,
  `daily-resting-heart-rate`, `respiratory-rate`, `oxygen-saturation`,
  `daily-sleep-temperature-derivations`, `sleep`, `vo2-max`, `exercise`. HRV is
  the daily summary (RMSSD/DFA need a beat-to-beat series, which Google doesn't
  expose), so recovery uses it the way it uses HealthKit's SDNN.

### Configuring Google Health

1. In Google Cloud Console, create a project, **enable the Google Health API**,
   and create an **OAuth 2.0 iOS client**.
2. Paste the client id into `Health/GoogleHealth.swift` → `GoogleHealthConfig.clientID`.
   The OAuth redirect (the reversed-client-id scheme) is derived automatically and
   intercepted by `ASWebAuthenticationSession`, so no Info.plist change is needed.
3. Until a real client id is set, the Google option reports "isn't set up yet" and
   the app stays on Apple Health.

Note: the `dataPoints` value field names aren't fully specified in the migration
docs, so the JSON parser is deliberately schema-resilient (it digs out the first
numeric/stage value). Verify against a live account and tighten if needed.

## Bluetooth band (offline, no cloud)

The **Bluetooth band** source pairs directly with your band and records on the
iPhone itself, with no account and no cloud:

- **Link:** the standard Bluetooth Heart Rate profile (service `0x180D`,
  measurement `0x2A37`, plus Battery `0x180F` and Device Info `0x180A`). It
  works with a **Fitbit Air** (Google Health app → device → *Share heart rate*,
  and *Always visible* for background recording) and any chest strap or band
  that broadcasts standard heart rate.
- **Recording:** `Bluetooth/BandManager.swift` keeps a pending connection open,
  auto-reconnects when the band comes back in range, runs in the background
  (`bluetooth-central`) and is relaunched by iOS state restoration. Every HR
  reading and every beat-to-beat interval is written to compact daily binary
  files (`Bluetooth/StreamStore.swift`, Application Support/Streams). Data is
  only recorded while the phone is in range: the band's own history syncs only
  through Google's cloud, which this source deliberately doesn't use.
- **Analysis** (`Algorithms/Band/`, all on-device):
  - sleep detection from the overnight HR drop, plus a 30-second
    wake/light/deep/REM hypnogram from HR, Walch difference-of-Gaussians HR
    variability, RMSSD and breathing variability (`HRSleepAnalyzer`);
  - HRV as the mean of 5-minute RMSSD windows, with range + Malik ectopic
    cleaning (`BeatHRV`);
  - resting HR as the lowest 5-minute bin mean while asleep;
  - breathing rate from respiratory sinus arrhythmia in the beats
    (`RespirationFromBeats`);
  - retroactive workout detection with Keytel calories (`HRWorkoutDetector`).
- **Scoring:** the band uses the **open-science model**
  (`Algorithms/Band/OpenScienceScoring.swift`): HRV-led Charge vs
  winsorised-EWMA baselines, Edwards %HRR TRIMP strain on a log curve, the Rest
  composite, 55% sleep-debt carry-over, and a 2-signal illness early-warning.
  These follow the methods the [NOOP](https://github.com/ryanbr/noop) project
  documents. They're an independent implementation; no NOOP source code is
  included. You can switch models in Settings → Advanced.

Without an accelerometer channel, sleep/wake rests on heart rate alone and
staging is approximate. Blood oxygen and skin temperature aren't part of the
open heart-rate profile.

## All sources at once

The **All sources** option (`Health/CombinedDataProvider.swift`) reads Apple
Health, Google Health and the Bluetooth band in parallel and blends them with
`Health/SourceMerger.swift`. Each slice of data comes from whichever source has
it first; when a better source catches up, it takes over on the next sync:

| Data | Priority | Unit of choice |
|---|---|---|
| Heart rate | band → Apple Health → Google | per minute (gaps filled by the next source) |
| Beat-to-beat intervals | band → Apple Health → Google | per night (never mixed) |
| HRV, resting HR, breathing | band → Apple Health → Google | per day |
| Sleep | Apple Health → band → Google | per night, one hypnogram; staged beats unstaged, fragments < 60 min lose |
| SpO₂, skin temp, VO₂ max | Apple Health → Google | per day |
| Workouts | union, overlaps ≥ 50% merged | the higher-priority copy borrows HR / calories |

Every source call has its own 45-second limit. A slow or failing source is
skipped for that sync, and Settings shows each source's status. Each source can
be turned on or off, and Google joins only once you're signed in, the band only
once paired.

## AI coach (optional, your own API key)

A daily brief and a chat on the Today tab, answered by **Anthropic (Claude,
default Claude Opus 5.5)** or **OpenAI (ChatGPT, default GPT-5)**
(`AI/AIClient.swift`, `AI/AICoach.swift`, `AI/CoachContext.swift`).

- **Off until you set it up** in Settings → AI coach: pick a provider and paste
  your API key (stored in the Keychain). Requests go straight from the iPhone
  to the provider, with no OutPerform server in between, and are billed to
  your provider account.
- **Your data is shared only if you opt in** ("Share my health data", off by
  default), and then only as a text summary of your last 14 days of scores,
  profile basics, zones and (optionally) recorded workouts. *Preview what's
  sent* shows the exact text. Raw heart rate, heartbeats, GPS routes and device
  IDs are never sent.
- Replies stream in; the conversation is stored only on the phone. Models are
  loaded from each provider's `/v1/models`. Claude requests opt into
  Anthropic's server-side refusal fallback where the model supports it.
- Not medical advice.

## Architecture

```
Models/        CoreTypes (samples, stages, zones), DailyRecord (SwiftData), AppSettings
Algorithms/    Pure, dependency-free score maths (unit-testable with `swiftc`)
Health/        Provider protocol + HealthKit / Google Health / Bluetooth band backends + Keychain
Bluetooth/     CoreBluetooth band client, HR packet decoder, on-device stream store
Engine/        ScoreEngine (orchestration), Background & Notification managers
Views/         SwiftUI screens (Today, Sleep, Strain, Body, Trends, Settings, Onboarding)
App/           AppModel coordinator
```

`ScoreEngine.refresh()` bulk-fetches the range once, then walks days
chronologically so baselines, sleep debt and the ACWR EWMA carry forward
correctly, persisting one `DailyRecord` per day.

## Building & running

```bash
open OutPerform/OutPerform.xcodeproj    # then ⌘R, or:
xcodebuild -scheme OutPerform -destination 'platform=iOS Simulator,name=iPhone 17' build
```

The app reads only real data, so run it on a **device** with Apple Health data
(or a connected Google Health account). You must enable the *HealthKit* capability for the App ID
(automatic signing usually handles this via `OutPerform.entitlements`).

## Calibration (spec §10)

Days 1–7 collect data, 8–13 show provisional scores, day 14+ full scores once
baselines are reliable, day 30+ unlocks personalised weight learning.

## Disclaimer

Not a medical device. The sleep-apnea (ODI) and illness features are
informational screening only and never a diagnosis.
