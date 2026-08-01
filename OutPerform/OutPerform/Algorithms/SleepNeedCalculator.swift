//
//  SleepNeedCalculator.swift
//  OutPerform
//
//  Sleep need (dynamic model), bedtime planner and chronotype —
//
//

import Foundation

public struct SleepNeedResult: Sendable {
    public var needMinutes: Double
    public var baselineMinutes: Double
    public var strainComponentMinutes: Double
    public var debtComponentMinutes: Double
    public var napMinutes: Double
    public var newDebtMinutes: Double      // carried into tomorrow
}

public enum SleepNeedCalculator {

    public static let defaultBaselineMinutes = 480.0   // 8h fallback

    /// Baseline = mean sleep on low-strain (<8) days over the last 30 days.
    public static func baseline(lowStrainSleepMinutes xs: [Double]) -> Double {
        xs.isEmpty ? defaultBaselineMinutes : Stats.mean(xs)
    }

    /// Strain component f1 — dynamic sleep-need formula. Returns extra minutes.
    /// f1(strain) = 1.7 / (1 + e^((17 - strain)/3.5))  hours → minutes.
    public static func strainComponentMinutes(strain: Double) -> Double {
        let hours = 1.7 / (1 + exp((17 - strain) / 3.5))
        return hours * 60
    }

    /// Debt component f2 = min(debt * 0.5, 90).
    public static func debtComponentMinutes(debt: Double) -> Double {
        min(max(debt, 0) * 0.5, 90)
    }

    /// Update accumulated sleep debt, clipped to 0...180 min.
    public static func updatedDebt(previousDebt: Double,
                                   previousNeed: Double,
                                   previousActual: Double) -> Double {
        let raw = previousDebt + (previousNeed - previousActual)
        return Stats.clamp(raw, 0, 180)
    }

    public static func sleepNeed(baselineMinutes: Double,
                                 yesterdayStrain: Double,
                                 carriedDebt: Double,
                                 napMinutes: Double) -> SleepNeedResult {
        let strainPart = strainComponentMinutes(strain: yesterdayStrain)
        let debtPart = debtComponentMinutes(debt: carriedDebt)
        let need = max(0, baselineMinutes + strainPart + debtPart - napMinutes)
        return SleepNeedResult(needMinutes: need,
                               baselineMinutes: baselineMinutes,
                               strainComponentMinutes: strainPart,
                               debtComponentMinutes: debtPart,
                               napMinutes: napMinutes,
                               newDebtMinutes: carriedDebt)
    }

    // MARK: Bedtime planner

    public enum PerformanceTarget: String, Sendable, CaseIterable, Codable {
        case peak, good, minimum
        public var multiplier: Double {
            switch self {
            case .peak: return 1.00
            case .good: return 0.85
            case .minimum: return 0.75
            }
        }
        public var displayName: String {
            switch self {
            case .peak: return "Peak (100%)"
            case .good: return "Good (85%)"
            case .minimum: return "Minimum (75%)"
            }
        }
    }

    /// Recommended bedtime = wake − need×target − latency, adjusted for chronotype.
    public static func bedtime(desiredWake: Date,
                               needMinutes: Double,
                               target: PerformanceTarget,
                               sleepLatencyMin: Double = 15,
                               chronotype: Chronotype? = nil) -> Date {
        let effectiveNeed = needMinutes * target.multiplier
        var seconds = -(effectiveNeed + sleepLatencyMin) * 60
        if let c = chronotype {
            switch c {            // ±60 min nudge
            case .earlyBird: seconds += -30 * 60
            case .nightOwl:  seconds += 30 * 60
            case .neutral:   break
            }
        }
        return desiredWake.addingTimeInterval(seconds)
    }

    // MARK: Chronotype

    /// Classify chronotype from mid-sleep points (hours past midnight) on free days.
    public static func chronotype(midSleepHoursOnFreeDays xs: [Double]) -> Chronotype? {
        guard !xs.isEmpty else { return nil }
        let msf = Stats.mean(xs)
        switch msf {
        case ..<2:  return .earlyBird
        case ..<4:  return .neutral
        default:    return .nightOwl
        }
    }
}
