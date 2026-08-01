//
//  ReadinessCalculator.swift
//  OutPerform
//
//  Unified daily Readiness score (0–100) combining recovery, sleep and the
//  ACWR load factor — a single unified daily readiness number.
//

import Foundation

public enum ReadinessCalculator {

    /// 100 inside the 0.8–1.3 ACWR sweet spot, tapering 30 points per unit of
    /// distance outside it.
    public static func acwrFactor(ratio: Double) -> Double {
        guard ratio > 0 else { return 100 }   // no load history yet → neutral
        if ratio >= 0.8 && ratio <= 1.3 { return 100 }
        let distance = ratio < 0.8 ? (0.8 - ratio) : (ratio - 1.3)
        return Stats.clamp(100 - distance * 30, 0, 100)
    }

    /// Readiness = recovery×0.60 + sleepPerf×0.25 + acwrFactor×0.15.
    public static func readiness(recovery: Double, sleepPerformance: Double, acwrRatio: Double) -> Double {
        let factor = acwrFactor(ratio: acwrRatio)
        return Stats.clamp(recovery * 0.60 + sleepPerformance * 0.25 + factor * 0.15, 0, 100)
    }
}
