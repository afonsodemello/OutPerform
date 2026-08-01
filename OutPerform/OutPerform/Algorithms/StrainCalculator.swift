//
//  StrainCalculator.swift
//  OutPerform
//
//  Strain (0–21) via TRIMP, plus the ACWR injury-risk layer and training
//  training monotony
//

import Foundation

public enum StrainCalculator {

    // MARK: Max heart rate

    /// Gellish non-linear estimate.
    public static func gellishHRMax(age: Int) -> Double {
        192 - 0.007 * Double(age) * Double(age)
    }

    public enum HRMaxMethod: String, Sendable { case gellish, learned, max }

    /// Personalised HRmax. Method is user-selectable.
    public static func personalisedHRMax(age: Int, allHeartRates: [Double],
                                         method: HRMaxMethod = .max) -> Double {
        let gellish = gellishHRMax(age: age)
        guard allHeartRates.count > 50 else { return gellish }
        let learned = Stats.percentile(allHeartRates, 0.95)
        switch method {
        case .gellish: return gellish
        case .learned: return learned
        case .max: return Swift.max(gellish, learned)
        }
    }

    // MARK: HR zones

    /// Returns the TRIMP weight (0...5) for a heart rate given HRmax.
    public static func zoneWeight(hr: Double, hrMax: Double) -> Int {
        guard hrMax > 0 else { return 0 }
        let pct = hr / hrMax
        switch pct {
        case ..<0.50: return 0
        case ..<0.60: return 1
        case ..<0.70: return 2
        case ..<0.80: return 3
        case ..<0.90: return 4
        default:      return 5
        }
    }

    // MARK: TRIMP

    /// TRIMP from heart-rate samples, binned into 1-minute buckets.
    /// Each minute contributes `zone_weight` TRIMP points.
    public static func trimp(heartRates samples: [QuantitySample], hrMax: Double) -> Double {
        guard !samples.isEmpty, hrMax > 0 else { return 0 }
        let sorted = samples.sorted { $0.start < $1.start }
        // Group by minute-of-epoch, average the HR within each minute.
        var minuteBuckets: [Int: [Double]] = [:]
        for s in sorted {
            let minute = Int(s.start.timeIntervalSince1970 / 60)
            minuteBuckets[minute, default: []].append(s.value)
        }
        var total = 0.0
        for (_, hrs) in minuteBuckets {
            let avg = Stats.mean(hrs)
            total += Double(zoneWeight(hr: avg, hrMax: hrMax))
        }
        return total
    }

    /// Apply the muscular-load multiplier for strength/HIIT/yoga.
    public static func adjustedTRIMP(_ trimp: Double, activity: WorkoutActivity) -> Double {
        trimp * activity.muscularLoadMultiplier
    }

    // MARK: TRIMP → 0–21 strain

    // Logarithmic mapping. The constants are deliberately exposed
    // as tunable: a near-sedentary day lands in the low single digits while a
    // very active day approaches the high teens, harder to gain at the top.
    public static let trimpScale = 150.0
    public static let strainCoefficient = 4.8

    public static func strain(fromTRIMP trimp: Double,
                              scale: Double = trimpScale,
                              coefficient: Double = strainCoefficient) -> Double {
        guard trimp > 0 else { return 0 }
        let s = coefficient * log(1 + trimp / scale)
        return Stats.clamp(s, 0, 21)
    }

    // MARK: ACWR — Acute:Chronic Workload Ratio

    public struct ACWRState: Sendable {
        public var ewmaAcute: Double
        public var ewmaChronic: Double
        public var ratio: Double { ewmaChronic > 0 ? ewmaAcute / ewmaChronic : 0 }
        public var zone: ACWRZone { ACWRZone(ratio: ratio) }
    }

    public static let lambdaAcute = 2.0 / (7.0 + 1.0)    // 0.25
    public static let lambdaChronic = 2.0 / (28.0 + 1.0) // 0.0667

    /// One EWMA update step using today's strain.
    public static func updateACWR(previous: ACWRState?, strainToday: Double) -> ACWRState {
        let prevA = previous?.ewmaAcute ?? strainToday
        let prevC = previous?.ewmaChronic ?? strainToday
        return ACWRState(
            ewmaAcute: Stats.ewma(previous: prevA, value: strainToday, lambda: lambdaAcute),
            ewmaChronic: Stats.ewma(previous: prevC, value: strainToday, lambda: lambdaChronic)
        )
    }

    // MARK: Training monotony

    public struct MonotonyResult: Sendable {
        public var monotony: Double
        public var trainingStrain: Double
        public var isHigh: Bool { monotony > 2.0 }
    }

    /// Foster's training monotony over the last 7 days of strain.
    public static func monotony(last7Strain xs: [Double]) -> MonotonyResult {
        guard !xs.isEmpty else { return MonotonyResult(monotony: 0, trainingStrain: 0) }
        let m = Stats.mean(xs)
        let s = Stats.stdDev(xs)
        let mono = s > 0 ? m / s : Double(xs.count)   // zero variance == max monotony
        let trainingStrain = xs.reduce(0, +) * mono
        return MonotonyResult(monotony: mono, trainingStrain: trainingStrain)
    }
}
