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

## Architecture

```
Models/        CoreTypes (samples, stages, zones), DailyRecord (SwiftData), AppSettings
Algorithms/    Pure, dependency-free score maths (unit-testable with `swiftc`)
Health/        Provider protocol + HealthKit / Google Health backends + Keychain
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
