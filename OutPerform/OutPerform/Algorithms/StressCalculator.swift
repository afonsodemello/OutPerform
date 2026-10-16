//
//  StressCalculator.swift
//  OutPerform
//
//  Real-time stress score (0–100) from HRV/HR deviation vs a 14-day baseline,
//  with a workout context gate so strain isn't misread as stress
//

import Foundation

nonisolated public enum StressCalculator {

    public struct Result: Sendable {
        public var score: Double            // 0–100
        public var suppressedByWorkout: Bool
        public var label: String {
            switch score {
            case ..<34: return "Calm"
            case ..<67: return "Moderate"
            default:    return "High"
            }
        }
    }

    /// raw_stress = (-HRV_z * 0.65) + (HR_z * 0.35); Stress = clip(50 + raw*15, 0, 100).
    public static func stress(currentHRV: Double, hrvMean14: Double, hrvStd14: Double,
                              currentHR: Double, hrMean14: Double, hrStd14: Double,
                              inWorkoutWindow: Bool) -> Result {
        guard !inWorkoutWindow else {
            return Result(score: 0, suppressedByWorkout: true)
        }
        let hrvZ = Stats.zScore(currentHRV, mean: hrvMean14, std: hrvStd14)
        let hrZ = Stats.zScore(currentHR, mean: hrMean14, std: hrStd14)
        let raw = (-hrvZ * 0.65) + (hrZ * 0.35)
        let score = Stats.clamp(50 + raw * 15, 0, 100)
        return Result(score: score, suppressedByWorkout: false)
    }
}
