//
//  MetricCatalog.swift
//  OutPerform
//
//  One description per metric: how to read its value off a DailyRecord, how it's
//  formatted, how it's calculated, and how many nights it needs before it's
//  meaningful. Drives the universal MetricDetailView so every number in the app
//  is tappable and fully explained.
//

import SwiftUI

enum MetricKind: String, CaseIterable, Identifiable {
    case readiness, recovery, strain, activityStrain, sleepPerformance
    case cognitiveReadiness
    case hrv, dfaAlpha1, restingHR, respiratoryRate, spo2, skinTemp, vo2Max
    case stress, acwr, monotony, sleepNeed, sleepDebt
    case totalSleep, remSleep, deepSleep, lightSleep, sleepEfficiency, restorative, odi
    var id: String { rawValue }
    var info: MetricInfo { MetricInfo.all[self]! }
}

struct MetricInfo {
    let kind: MetricKind
    let title: String
    let unit: String
    let systemImage: String
    let tint: Color
    /// nil = neutral (no inherent good/bad direction).
    let higherIsBetter: Bool?
    let domain: ClosedRange<Double>?
    /// Nights of data required before the value is trustworthy.
    let calibrationDays: Int
    let value: (DailyRecord) -> Double?
    let format: (Double) -> String
    let howItWorks: String
    let related: [MetricKind]

    func valueString(_ r: DailyRecord) -> String {
        value(r).map(format) ?? "No data"
    }

    /// Colour for a given value (zone colours for scores, tint otherwise).
    func color(for v: Double?) -> Color {
        guard let v else { return .secondary }
        switch kind {
        case .readiness: return readinessColor(v)
        case .recovery: return RecoveryZone(score: v).color
        case .strain, .activityStrain: return StrainZone(strain: v).color
        case .cognitiveReadiness: return FocusZone(score: v).color
        case .acwr: return ACWRZone(ratio: v).color
        default: return tint
        }
    }
}

extension MetricInfo {
    static let all: [MetricKind: MetricInfo] = {
        var d: [MetricKind: MetricInfo] = [:]
        func add(_ i: MetricInfo) { d[i.kind] = i }

        let intMin: (Double) -> String = { Fmt.minutes($0) }
        let score: (Double) -> String = { "\(Int($0.rounded()))" }
        let pct: (Double) -> String = { "\(Int($0.rounded()))%" }

        add(.init(kind: .readiness, title: "Readiness", unit: "/100", systemImage: "bolt.heart.fill",
                  tint: .opGreen, higherIsBetter: true, domain: 0...100, calibrationDays: 14,
                  value: { $0.readiness }, format: score,
                  howItWorks: "OutPerform's single daily answer. Readiness = recovery×0.60 + sleep performance×0.25 + ACWR factor×0.15. The ACWR factor is 100 inside the 0.8–1.3 training-load sweet spot and tapers outside it. It folds your morning recovery, last night's sleep and your training-load balance into one number.",
                  related: [.recovery, .sleepPerformance, .acwr]))

        add(.init(kind: .recovery, title: "Recovery", unit: "%", systemImage: "arrow.clockwise.heart.fill",
                  tint: .opGreen, higherIsBetter: true, domain: 0...100, calibrationDays: 14,
                  value: { $0.recovery }, format: pct,
                  howItWorks: "Computed once each morning from last night. A weighted blend of HRV (≈40%), resting HR (≈25%), respiratory rate (≈10%) and sleep performance (≈25%), each compared to your personal rolling baseline as a z-score, then mapped to 0–100. Elevated skin temperature and low blood-oxygen apply penalties on top. Weights are adjustable in Settings → Advanced. Green 67–100, Yellow 34–66, Red 0–33.",
                  related: [.hrv, .restingHR, .respiratoryRate, .sleepPerformance, .skinTemp, .spo2]))

        add(.init(kind: .cognitiveReadiness, title: "Cognitive readiness", unit: "/100",
                  systemImage: "brain.head.profile", tint: .opPurple, higherIsBetter: true,
                  domain: 0...100, calibrationDays: 0,
                  value: { $0.cognitiveReadiness }, format: score,
                  howItWorks: "How \u{201C}locked in\u{201D} you can be, predicted from the Three-Process Model of alertness: homeostatic sleep pressure (alertness falls the longer you're awake, starting lower when sleep-deprived) + your circadian rhythm (a daily curve peaking late-afternoon with an early-afternoon dip, shifted by your chronotype) + sleep inertia (post-waking grogginess). HRV-vs-baseline and stress nudge the level. The stored value is the day's PEAK; the Focus tab shows the live time-of-day curve and your deep-work windows. It's a prediction — the reaction test on the Focus tab calibrates it to you.",
                  related: [.sleepDebt, .sleepPerformance, .stress, .hrv]))

        add(.init(kind: .strain, title: "Day strain", unit: "/21", systemImage: "flame.fill",
                  tint: .opBlue, higherIsBetter: nil, domain: 0...21, calibrationDays: 0,
                  value: { $0.dayStrain }, format: { String(format: "%.1f", $0) },
                  howItWorks: "Cardiovascular load on a 0–21 logarithmic scale. Every minute of heart rate is placed in one of five zones (% of max HR) and weighted 1–5 — this is TRIMP (Training Impulse, Banister 1991). Strain = coefficient × ln(1 + TRIMP / scale), capped at 21. It accumulates from midnight, so it's low early in the day. Curve constants and the max-HR method are adjustable in Settings → Advanced.",
                  related: [.activityStrain, .acwr, .monotony]))

        add(.init(kind: .activityStrain, title: "Activity strain", unit: "/21", systemImage: "figure.run",
                  tint: .opBlue, higherIsBetter: nil, domain: 0...21, calibrationDays: 0,
                  value: { $0.activityStrain }, format: { String(format: "%.1f", $0) },
                  howItWorks: "Strain from logged workouts only. Workout TRIMP gets a muscular-load multiplier (strength ×1.3, HIIT ×1.2, yoga ×1.1) before mapping to the 0–21 scale, so low-HR/high-effort sessions aren't under-counted.",
                  related: [.strain]))

        add(.init(kind: .sleepPerformance, title: "Sleep performance", unit: "%", systemImage: "bed.double.fill",
                  tint: .opPurple, higherIsBetter: true, domain: 0...100, calibrationDays: 0,
                  value: { $0.sleepPerformance }, format: pct,
                  howItWorks: "How good last night was, 0–100. Weighted blend of efficiency (time asleep ÷ time in bed, 30%), restorative ratio (REM+deep ÷ total, where 40% = perfect, 30%), need fulfilment (slept ÷ needed, 25%) and consistency of bed time (15%). Weights adjustable in Settings → Advanced.",
                  related: [.totalSleep, .sleepEfficiency, .restorative, .sleepNeed]))

        add(.init(kind: .hrv, title: "HRV", unit: "ms", systemImage: "waveform.path.ecg",
                  tint: .opGreen, higherIsBetter: true, domain: nil, calibrationDays: 0,
                  value: { $0.hrv }, format: { "\(Int($0.rounded())) ms" },
                  howItWorks: "Heart-rate variability during sleep — the strongest recovery signal. When an Apple Watch records a beat-to-beat series, OutPerform computes RMSSD (root-mean-square of successive RR-interval differences) and the nonlinear DFA-α1; otherwise it uses the SDNN value your wearable wrote. Higher generally means better-recovered.",
                  related: [.dfaAlpha1, .recovery]))

        add(.init(kind: .dfaAlpha1, title: "DFA-α1", unit: "", systemImage: "function",
                  tint: .opPurple, higherIsBetter: true, domain: 0...1.5, calibrationDays: 0,
                  value: { $0.dfaAlpha1 }, format: { String(format: "%.2f", $0) },
                  howItWorks: "Detrended Fluctuation Analysis α1 — an advanced nonlinear HRV metric most trackers don't expose. It measures the fractal correlation of your heartbeat series. ≈1.0 at rest signals a well-recovered autonomic state; sustained values below 0.8 indicate lingering fatigue even when RMSSD looks normal. Needs a beat-to-beat series (Apple Watch).",
                  related: [.hrv]))

        add(.init(kind: .restingHR, title: "Resting HR", unit: "bpm", systemImage: "heart.fill",
                  tint: .opRed, higherIsBetter: false, domain: nil, calibrationDays: 0,
                  value: { $0.restingHR }, format: { "\(Int($0.rounded())) bpm" },
                  howItWorks: "Your lowest sustained heart rate during sleep — the 5th percentile of sleep HR, not the raw minimum, to avoid noise. Compared to your 7-day baseline: below baseline is positive for recovery, elevated suggests stress, illness or overtraining.",
                  related: [.recovery, .vo2Max]))

        add(.init(kind: .respiratoryRate, title: "Respiratory rate", unit: "br/min", systemImage: "lungs.fill",
                  tint: .opBlue, higherIsBetter: false, domain: nil, calibrationDays: 0,
                  value: { $0.respiratoryRate }, format: { String(format: "%.1f", $0) },
                  howItWorks: "Breaths per minute during sleep. Usually very stable night to night, so a rise above your 14-day baseline is often the first sign of illness or strain. Normal sleep range is ~12–20.",
                  related: [.recovery]))

        add(.init(kind: .spo2, title: "Blood oxygen", unit: "%", systemImage: "drop.fill",
                  tint: .opBlue, higherIsBetter: true, domain: 85...100, calibrationDays: 0,
                  value: { $0.spo2Avg }, format: pct,
                  howItWorks: "Average overnight oxygen saturation. ≥96% is normal; lower values apply a recovery penalty and, if recurring, may indicate sleep-disordered breathing — see the apnea screening (ODI).",
                  related: [.odi, .recovery]))

        add(.init(kind: .skinTemp, title: "Skin temperature", unit: "°C", systemImage: "thermometer.medium",
                  tint: .opYellow, higherIsBetter: nil, domain: nil, calibrationDays: 0,
                  value: { $0.skinTempC }, format: { String(format: "%.1f°C", $0) },
                  howItWorks: "Wrist temperature during sleep, read as a deviation from your 14-day baseline. More than +0.5°C applies a recovery penalty and is an early signal of illness, overtraining or hormonal shifts; a slight dip can mark deep recovery.",
                  related: [.recovery]))

        add(.init(kind: .vo2Max, title: "VO₂ max", unit: "mL/kg·min", systemImage: "lungs.fill",
                  tint: .opGreen, higherIsBetter: true, domain: nil, calibrationDays: 0,
                  value: { $0.vo2Max }, format: { String(format: "%.0f", $0) },
                  howItWorks: "Maximum rate of oxygen use — the single best predictor of longevity. Uses Apple Health's own estimate when available, otherwise approximates it from your max-HR ÷ resting-HR ratio. Classified against age/sex norms (elite/good/average/poor).",
                  related: [.restingHR]))

        add(.init(kind: .stress, title: "Stress", unit: "/100", systemImage: "waveform.path",
                  tint: .opYellow, higherIsBetter: false, domain: 0...100, calibrationDays: 14,
                  value: { $0.stress }, format: score,
                  howItWorks: "Real-time stress from HRV and HR vs your 14-day baseline. raw = (−HRV_z×0.65) + (HR_z×0.35); Stress = 50 + raw×15, clamped 0–100. Logged-workout periods are excluded so physical strain isn't misread as stress. Try the breathwork tools to lower it.",
                  related: [.hrv, .restingHR]))

        add(.init(kind: .acwr, title: "ACWR", unit: "ratio", systemImage: "figure.run.circle",
                  tint: .opGreen, higherIsBetter: nil, domain: 0...2, calibrationDays: 14,
                  value: { $0.acwr }, format: { String(format: "%.2f", $0) },
                  howItWorks: "Acute:Chronic Workload Ratio — an injury-risk layer pro teams use. Acute load (this week) ÷ chronic load (4-week average), via EWMA smoothing. Sweet spot 0.8–1.3; above 1.5 means your load spiked. Informational, not a prediction — needs ~14 nights of history first.",
                  related: [.strain, .monotony]))

        add(.init(kind: .monotony, title: "Training monotony", unit: "ratio", systemImage: "repeat",
                  tint: .opBlue, higherIsBetter: false, domain: 0...4, calibrationDays: 7,
                  value: { $0.monotony }, format: { String(format: "%.2f", $0) },
                  howItWorks: "Foster's monotony = mean ÷ standard deviation of the last 7 days of strain. High monotony (>2.0) means you train the same amount every day, which raises burnout and injury risk even at moderate load. Lower = healthier variety.",
                  related: [.strain, .acwr]))

        add(.init(kind: .sleepNeed, title: "Sleep need", unit: "", systemImage: "alarm.fill",
                  tint: .opPurple, higherIsBetter: nil, domain: nil, calibrationDays: 0,
                  value: { $0.sleepNeedMin }, format: intMin,
                  howItWorks: "How much sleep you need tonight, from a dynamic sleep-need model: baseline (your average on low-strain days) + a strain term f1 = 1.7/(1+e^((17−strain)/3.5)) hours + half of any accumulated debt − naps. Drives the bedtime recommendation.",
                  related: [.sleepDebt, .strain, .sleepPerformance]))

        add(.init(kind: .sleepDebt, title: "Sleep debt", unit: "", systemImage: "hourglass",
                  tint: .opYellow, higherIsBetter: false, domain: nil, calibrationDays: 0,
                  value: { $0.sleepDebtMin }, format: intMin,
                  howItWorks: "Accumulated shortfall of sleep vs need, carried across nights and capped at 3 hours. Half of it is added back to tonight's need so you repay it gradually rather than in one long sleep.",
                  related: [.sleepNeed]))

        add(.init(kind: .totalSleep, title: "Time asleep", unit: "", systemImage: "moon.zzz.fill",
                  tint: .opPurple, higherIsBetter: true, domain: nil, calibrationDays: 0,
                  value: { $0.totalSleepMin }, format: intMin,
                  howItWorks: "Total minutes across all non-awake stages last night. Stages come straight from Apple Health (your wearable classifies them).",
                  related: [.remSleep, .deepSleep, .lightSleep, .sleepEfficiency]))

        add(.init(kind: .remSleep, title: "REM sleep", unit: "", systemImage: "brain.head.profile",
                  tint: .opPurple, higherIsBetter: true, domain: nil, calibrationDays: 0,
                  value: { $0.remMin }, format: intMin,
                  howItWorks: "Dreaming sleep, important for memory and mood. Target is roughly 20–25% of total sleep. Counts toward the restorative ratio.",
                  related: [.deepSleep, .restorative]))

        add(.init(kind: .deepSleep, title: "Deep sleep", unit: "", systemImage: "moon.fill",
                  tint: .indigo, higherIsBetter: true, domain: nil, calibrationDays: 0,
                  value: { $0.deepMin }, format: intMin,
                  howItWorks: "Slow-wave (N3) sleep — the most physically restorative stage. Target ~20–25% of total. Counts toward the restorative ratio.",
                  related: [.remSleep, .restorative]))

        add(.init(kind: .lightSleep, title: "Light sleep", unit: "", systemImage: "moon.stars.fill",
                  tint: .opBlue, higherIsBetter: nil, domain: nil, calibrationDays: 0,
                  value: { $0.coreMin }, format: intMin,
                  howItWorks: "Core / N1–N2 sleep — the largest portion of a normal night and the bridge between deep and REM cycles.",
                  related: [.totalSleep]))

        add(.init(kind: .sleepEfficiency, title: "Sleep efficiency", unit: "%", systemImage: "percent",
                  tint: .opGreen, higherIsBetter: true, domain: 0...100, calibrationDays: 0,
                  value: { $0.sleepEfficiency }, format: pct,
                  howItWorks: "Time asleep ÷ time in bed × 100. High efficiency means you fall and stay asleep; low efficiency points to restlessness or long awakenings.",
                  related: [.totalSleep, .sleepPerformance]))

        add(.init(kind: .restorative, title: "Restorative sleep", unit: "%", systemImage: "heart.circle.fill",
                  tint: .opPurple, higherIsBetter: true, domain: 0...100, calibrationDays: 0,
                  value: { $0.restorativePct }, format: pct,
                  howItWorks: "(REM + deep) ÷ total sleep × 100. These are the stages that rebuild body and brain; ~40% is the target used in the sleep-performance score.",
                  related: [.remSleep, .deepSleep, .sleepPerformance]))

        add(.init(kind: .odi, title: "Apnea screening (ODI)", unit: "/hr", systemImage: "stethoscope",
                  tint: .opYellow, higherIsBetter: false, domain: nil, calibrationDays: 0,
                  value: { $0.odi }, format: { String(format: "%.1f", $0) },
                  howItWorks: "Oxygen Desaturation Index — overnight SpO₂ drops of ≥3% lasting ≥10s, per hour of sleep. <5 normal, 5–15 mild, 15–30 moderate, >30 severe. Screening only — never a diagnosis. If consistently elevated, ask a doctor about a sleep study.",
                  related: [.spo2]))

        return d
    }()
}
