//
//  VO2MaxCalculator.swift
//  OutPerform
//
//  VO2 max — prefer HealthKit's own estimate, otherwise approximate from the
//  resting-HR / HRmax ratio
//

import Foundation

nonisolated public enum FitnessLevel: String, Sendable {
    case poor, average, good, elite
    public var displayName: String { rawValue.capitalized }
}

nonisolated public enum VO2MaxCalculator {

    /// Rough fallback: VO2max ≈ 15 × (HRmax / RHR).
    public static func estimate(hrMax: Double, restingHR: Double) -> Double? {
        guard restingHR > 0, hrMax > 0 else { return nil }
        return 15 * (hrMax / restingHR)
    }

    /// Age/sex classification. Thresholds are the headline bands.
    public static func classify(vo2: Double, sex: BiologicalSex) -> FitnessLevel {
        let isFemale = sex == .female
        let elite = isFemale ? 50.0 : 55.0
        let good  = isFemale ? 40.0 : 45.0
        let avg   = isFemale ? 30.0 : 35.0
        switch vo2 {
        case elite...:     return .elite
        case good..<elite: return .good
        case avg..<good:   return .average
        default:           return .poor
        }
    }
}
