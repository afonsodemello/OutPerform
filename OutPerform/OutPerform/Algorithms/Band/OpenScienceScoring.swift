//
//  OpenScienceScoring.swift
//  OutPerform
//
//  The open-science scoring model (the methods NOOP documents in its
//  ANALYTICS.md, implemented independently here):
//
//   • Personal baselines: winsorised EWMA centre + EWMA mean-absolute-
//     deviation spread, half-lives 14 / 21 nights.
//   • Charge (recovery, 0–100): robust z-scores vs baseline, weighted
//     HRV .55 / RHR .20 / sleep .15 / resp .05 / skin-temp .05, squashed by a
//     logistic anchored so "at baseline" ≈ 58%.
//   • Effort (strain): Karvonen %HRR → Edwards 5-zone TRIMP →
//     ln(TRIMP+1)/ln(7201). Stored on the app's 0–21 scale
//     (Effort 0–100 = strain × 100/21).
//   • Rest (sleep performance, 0–100): duration vs need .50, efficiency .20,
//     restorative share .20, consistency .10.
//   • Sleep debt: 55% of unmet need carries into the next night, < 10 min
//     counts as balanced.
//   • Illness early-warning: last 2 days vs a ~28-day baseline ending 3 days
//     ago; two or more of RHR↑ / HRV↓ / temp↑ / resp↑ together.
//
//  Every score is approximate and none of this is a medical device.
//

import Foundation

nonisolated public enum ScoringModel: String, CaseIterable, Codable, Sendable {
    /// OutPerform's original formulas.
    case outperform
    /// Open-science model (NOOP methods).
    case openScience

    public var displayName: String {
        switch self {
        case .outperform:  return "OutPerform classic"
        case .openScience: return "Open-science"
        }
    }
}

nonisolated public enum ScoreConfidence: String, Sendable {
    case calibrating, building, solid
    public var label: String {
        switch self {
        case .calibrating: return "Calibrating"
        case .building:    return "Building"
        case .solid:       return "Solid"
        }
    }
}

// MARK: - Baselines

nonisolated public struct BaselineState: Sendable {
    public var baseline: Double
    public var spread: Double
    public var nights: Int

    public static let minNightsSeed = 4
    public static let minNightsTrust = 14

    public var usable: Bool { nights >= Self.minNightsSeed }
    public var confidence: ScoreConfidence {
        nights < Self.minNightsSeed ? .calibrating : nights < Self.minNightsTrust ? .building : .solid
    }
}

nonisolated public enum Baselines {
    public struct MetricConfig: Sendable {
        public var minVal: Double, maxVal: Double, floorSpread: Double
        public var centerHalfLife = 14.0, spreadHalfLife = 21.0
    }

    public static let hrv = MetricConfig(minVal: 5, maxVal: 250, floorSpread: 5)
    public static let restingHR = MetricConfig(minVal: 30, maxVal: 120, floorSpread: 2)
    public static let resp = MetricConfig(minVal: 4, maxVal: 40, floorSpread: 0.5)
    public static let skinTemp = MetricConfig(minVal: 20, maxVal: 42, floorSpread: 0.3)

    static let winsorK = 3.0
    static let hardOutlierK = 5.0

    static func lambda(_ halfLife: Double) -> Double { 1 - pow(0.5, 1 / halfLife) }

    /// Fold one night into the baseline.
    public static func update(_ state: BaselineState?, value: Double, cfg: MetricConfig) -> BaselineState? {
        guard value >= cfg.minVal, value <= cfg.maxVal else { return state }   // skip-and-hold
        guard var s = state else {
            return BaselineState(baseline: value, spread: cfg.floorSpread * 2, nights: 1)
        }
        if s.nights >= BaselineState.minNightsSeed, abs(value - s.baseline) > hardOutlierK * s.spread {
            return s   // seen but not folded
        }
        let lb = lambda(cfg.centerHalfLife), ls = lambda(cfg.spreadHalfLife)
        let clamped = Stats.clamp(value, s.baseline - winsorK * s.spread, s.baseline + winsorK * s.spread)
        let newBaseline = lb * clamped + (1 - lb) * s.baseline
        let newSpread = max(cfg.floorSpread, ls * abs(value - newBaseline) + (1 - ls) * s.spread)
        s.baseline = newBaseline
        s.spread = newSpread
        s.nights += 1
        return s
    }

    public static func fold(_ values: [Double], cfg: MetricConfig) -> BaselineState? {
        values.reduce(nil) { update($0, value: $1, cfg: cfg) }
    }

    /// Robust z: EWMA mean-absolute-deviation × 1.253 ≈ Gaussian σ.
    public static func z(_ value: Double, _ s: BaselineState) -> Double {
        (value - s.baseline) / (1.253 * max(s.spread, 1e-6))
    }
}

// MARK: - Charge (recovery)

nonisolated public enum ChargeScorer {
    public static let wHRV = 0.55, wRHR = 0.20, wSleep = 0.15, wResp = 0.05, wSkinTemp = 0.05
    public static let logisticK = 1.6
    public static let logisticZ0 = -0.20

    public struct Input: Sendable {
        public var hrv: Double?
        public var restingHR: Double?
        public var sleepPerformance: Double?   // 0–100
        public var respiratoryRate: Double?
        public var skinTempC: Double?
        public var spo2Avg: Double?
        public var hrvBaseline: BaselineState?
        public var rhrBaseline: BaselineState?
        public var respBaseline: BaselineState?
        public var tempBaseline: BaselineState?
    }

    /// HRV-led when HRV and its baseline exist. On a night with no HRV from
    /// any source, falls back to resting HR (+ sleep, breathing, temp) against
    /// its own baseline, capped at "Building" confidence, so a source without
    /// HRV still gets a recovery score. nil while baselines are calibrating.
    public static func score(_ i: Input) -> (score: Double, confidence: ScoreConfidence)? {
        var terms: [(w: Double, z: Double)] = []
        let confidence: ScoreConfidence
        if let hrv = i.hrv, let hb = i.hrvBaseline, hb.usable {
            terms.append((wHRV, Baselines.z(hrv, hb)))
            confidence = hb.confidence
        } else if i.restingHR != nil, let rb = i.rhrBaseline, rb.usable {
            confidence = rb.confidence == .solid ? .building : rb.confidence
        } else {
            return nil
        }
        if let v = i.restingHR, let b = i.rhrBaseline, b.usable { terms.append((wRHR, -Baselines.z(v, b))) }
        if let sp = i.sleepPerformance { terms.append((wSleep, (sp / 100 - 0.85) / 0.12)) }
        if let v = i.respiratoryRate, let b = i.respBaseline, b.usable { terms.append((wResp, -Baselines.z(v, b))) }
        if let v = i.skinTempC, let b = i.tempBaseline, b.usable { terms.append((wSkinTemp, -abs(Baselines.z(v, b)))) }
        let wSum = terms.reduce(0) { $0 + $1.w }
        let z = terms.reduce(0) { $0 + $1.w * $1.z } / wSum
        var score = 100 / (1 + exp(-logisticK * (z - logisticZ0)))
        // SpO2 folds in only when a real value exists: small penalty below 95%.
        if let s = i.spo2Avg, s < 95 { score -= min(10, (95 - s) * 2) }
        return (Stats.clamp(score, 0, 100), confidence)
    }
}

// MARK: - Effort (strain)

nonisolated public enum EffortScorer {
    public static let denominator = 7201.0
    public static let minReadingMinutes = 10   // ≈ NOOP's 600 one-second samples
    public static let edwardsCutoffs = [0.50, 0.60, 0.70, 0.80, 0.90]

    /// Tanaka (2001), or the observed 99.5th percentile when there is enough
    /// data and it is higher.
    public static func hrMax(age: Int, observed: [Double]) -> Double {
        let tanaka = 208 - 0.7 * Double(age)
        guard observed.count >= 600 else { return tanaka }
        return max(tanaka, Stats.percentile(observed, 0.995))
    }

    /// Edwards TRIMP over %HRR. Each sample counts for its duration in minutes.
    public static func trimp(_ samples: [QuantitySample], restingHR: Double, hrMax: Double) -> Double? {
        guard hrMax > restingHR, samples.count >= minReadingMinutes else { return nil }
        let hrr = hrMax - restingHR
        var total = 0.0
        for s in samples {
            let pct = Stats.clamp((s.value - restingHR) / hrr, 0, 1)
            let zone = edwardsCutoffs.lastIndex { pct >= $0 }.map { $0 + 1 } ?? 0
            let minutes = s.end > s.start ? s.end.timeIntervalSince(s.start) / 60 : 1
            total += Double(zone) * minutes
        }
        return total
    }

    /// Logarithmic 0–21 strain (Effort 0–100 = × 100/21).
    public static func strain21(trimp: Double) -> Double {
        Stats.clamp(21 * log(trimp + 1) / log(denominator), 0, 21)
    }

    public static func effort100(strain21: Double) -> Double { strain21 * 100 / 21 }
}

// MARK: - Rest (sleep performance)

nonisolated public enum RestScorer {
    public static let wDuration = 0.50, wEfficiency = 0.20, wRestorative = 0.20, wConsistency = 0.10

    public static func score(metrics m: SleepMetrics, needMin: Double, bedtimeStdHours: Double) -> Double {
        let duration = needMin > 0 ? Stats.clamp(m.totalSleepMin / needMin, 0, 1) : 0
        let efficiency = Stats.clamp(m.efficiencyPct / 100, 0, 1)
        // ~45% deep+REM is a full-marks night.
        let restorative = Stats.clamp(m.restorativePct / 45, 0, 1)
        let consistency = Stats.clamp(1 - bedtimeStdHours / 1.5, 0, 1)
        return 100 * (wDuration * duration + wEfficiency * efficiency
                      + wRestorative * restorative + wConsistency * consistency)
    }
}

// MARK: - Sleep debt

nonisolated public enum SleepDebtModel {
    public static let carry = 0.55
    public static let deadbandMin = 10.0

    /// Debt carried into the next night.
    public static func nextDebt(baseNeedMin: Double, currentDebtMin: Double, sleptMin: Double) -> Double {
        let need = baseNeedMin + currentDebtMin
        let debt = carry * max(0, need - sleptMin)
        return debt < deadbandMin ? 0 : debt
    }
}

// MARK: - Illness early-warning

nonisolated public struct IllnessSignal: Sendable {
    public var restingHRDelta: Double?
    public var hrvPctChange: Double?
    public var tempDelta: Double?
    public var respDelta: Double?
    public var message: String
}

nonisolated public enum IllnessWatch {
    public struct Day: Sendable {
        public var restingHR, hrv, skinTempC, resp: Double?
        public init(restingHR: Double?, hrv: Double?, skinTempC: Double?, resp: Double?) {
            self.restingHR = restingHR; self.hrv = hrv; self.skinTempC = skinTempC; self.resp = resp
        }
    }

    /// `days` oldest → newest. Needs ≥ 14 days. Fires on ≥ 2 anomalies.
    public static func evaluate(_ days: [Day]) -> IllnessSignal? {
        guard days.count >= 14 else { return nil }
        let recent = Array(days.suffix(2))
        let base = Array(days.suffix(31).dropLast(3))
        func m(_ xs: [Day], _ k: KeyPath<Day, Double?>) -> Double? {
            let v = xs.compactMap { $0[keyPath: k] }
            return v.isEmpty ? nil : Stats.mean(v)
        }
        var parts: [String] = []
        var signal = IllnessSignal(message: "")
        if let r = m(recent, \.restingHR), let b = m(base, \.restingHR), r >= b + 5 {
            signal.restingHRDelta = r - b
            parts.append(String(format: "resting HR +%.0f bpm", r - b))
        }
        if let r = m(recent, \.hrv), let b = m(base, \.hrv), b > 0, r <= b * 0.80 {
            signal.hrvPctChange = (r / b - 1) * 100
            parts.append(String(format: "HRV %.0f%%", (r / b - 1) * 100))
        }
        if let r = m(recent, \.skinTempC), let b = m(base, \.skinTempC), r - b >= 0.6 {
            signal.tempDelta = r - b
            parts.append(String(format: "skin temp +%.1f °C", r - b))
        }
        if let r = m(recent, \.resp), let b = m(base, \.resp), r >= b + 1.5 {
            signal.respDelta = r - b
            parts.append(String(format: "breathing +%.1f /min", r - b))
        }
        guard parts.count >= 2 else { return nil }
        signal.message = "Your body looks strained — \(parts.joined(separator: ", ")). Consider taking it easy."
        return signal
    }
}
