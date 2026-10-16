//
//  RecoveryCalculator.swift
//  OutPerform
//
//  Morning recovery score (0–100%)
//  Weighted combination of HRV, resting HR, respiratory rate and sleep
//  performance, with skin-temperature and SpO2 penalties layered on top
//  (skin-temperature and SpO2 inputs–1.6).
//

import Foundation

nonisolated public struct RecoveryInput: Sendable {
    // Today's nightly values.
    public var rmssd: Double?
    public var restingHR: Double?
    public var respiratoryRate: Double?
    public var sleepPerformance: Double?   // 0–100, from SleepCalculator
    public var skinTempC: Double?
    public var spo2Avg: Double?            // percent, e.g. 96

    // Personal baselines (computed by the engine over prior nights).
    public var rmssdMean3: Double?
    public var rmssdStd7: Double?
    public var rhrMean7: Double?
    public var rhrStd14: Double?
    public var respMean14: Double?
    public var respStd14: Double?
    public var skinTempMean14: Double?

    public init(rmssd: Double? = nil, restingHR: Double? = nil, respiratoryRate: Double? = nil,
                sleepPerformance: Double? = nil, skinTempC: Double? = nil, spo2Avg: Double? = nil,
                rmssdMean3: Double? = nil, rmssdStd7: Double? = nil,
                rhrMean7: Double? = nil, rhrStd14: Double? = nil,
                respMean14: Double? = nil, respStd14: Double? = nil,
                skinTempMean14: Double? = nil) {
        self.rmssd = rmssd; self.restingHR = restingHR; self.respiratoryRate = respiratoryRate
        self.sleepPerformance = sleepPerformance; self.skinTempC = skinTempC; self.spo2Avg = spo2Avg
        self.rmssdMean3 = rmssdMean3; self.rmssdStd7 = rmssdStd7
        self.rhrMean7 = rhrMean7; self.rhrStd14 = rhrStd14
        self.respMean14 = respMean14; self.respStd14 = respStd14
        self.skinTempMean14 = skinTempMean14
    }
}

nonisolated public struct RecoveryResult: Sendable {
    public var score: Double
    public var zone: RecoveryZone
    // Component breakdown (each 0–100, 50 == baseline) for the UI.
    public var hrvScore: Double?
    public var rhrScore: Double?
    public var respScore: Double?
    public var sleepScore: Double?
    public var tempPenalty: Double   // <= 0
    public var spo2Penalty: Double   // <= 0
}

nonisolated public enum RecoveryCalculator {

    /// Tunable weights (Settings → Advanced); defaults from
    public struct Weights: Sendable {
        public var hrv: Double = 0.40
        public var rhr: Double = 0.25
        public var resp: Double = 0.10
        public var sleep: Double = 0.25
        public var includeTemp: Bool = true
        public var includeSpo2: Bool = true
        public init(hrv: Double = 0.40, rhr: Double = 0.25, resp: Double = 0.10, sleep: Double = 0.25,
                    includeTemp: Bool = true, includeSpo2: Bool = true) {
            self.hrv = hrv; self.rhr = rhr; self.resp = resp; self.sleep = sleep
            self.includeTemp = includeTemp; self.includeSpo2 = includeSpo2
        }
        public static let `default` = Weights()
    }

    /// Maps a z-score (capped at ±2 std) to a 0–100 contribution
    /// where 50 == personal baseline. Higher is always better.
    public static func scoreFromZ(_ z: Double) -> Double {
        let capped = Stats.clamp(z, -2, 2)
        return Stats.clamp(50 + 22 * capped, 0, 100)
    }

    public static func compute(_ i: RecoveryInput, weights: Weights = .default) -> RecoveryResult {
        var weighted = 0.0
        var totalWeight = 0.0

        // HRV — z of today's RMSSD vs 3-day mean / 7-day std.
        var hrvScore: Double?
        if let v = i.rmssd, let m = i.rmssdMean3, let s = i.rmssdStd7, s > 0 {
            let score = scoreFromZ(Stats.zScore(v, mean: m, std: s))
            hrvScore = score
            weighted += weights.hrv * score; totalWeight += weights.hrv
        }

        // Resting HR — positive when below baseline.
        var rhrScore: Double?
        if let v = i.restingHR, let m = i.rhrMean7, let s = i.rhrStd14, s > 0 {
            let z = (m - v) / s                       // below baseline → positive
            let score = scoreFromZ(z)
            rhrScore = score
            weighted += weights.rhr * score; totalWeight += weights.rhr
        }

        // Respiratory rate — inverted; higher than baseline is worse.
        var respScore: Double?
        if let v = i.respiratoryRate, let m = i.respMean14, let s = i.respStd14, s > 0 {
            let z = -((v - m) / s)
            let score = scoreFromZ(z)
            respScore = score
            weighted += weights.resp * score; totalWeight += weights.resp
        }

        // Sleep performance — already 0–100.
        var sleepScore: Double?
        if let v = i.sleepPerformance {
            sleepScore = Stats.clamp(v, 0, 100)
            weighted += weights.sleep * sleepScore!; totalWeight += weights.sleep
        }

        // Base score, re-normalised over available inputs. Falls back to 50
        // (neutral) before any baseline exists.
        let base = totalWeight > 0 ? weighted / totalWeight : 50

        // Skin-temperature penalty.
        var tempPenalty = 0.0
        if weights.includeTemp, let t = i.skinTempC, let m = i.skinTempMean14 {
            let dev = t - m
            if dev > 0.5 {
                // 0 at +0.5 °C, -10 at +1.5 °C and beyond.
                tempPenalty = -Stats.clamp((dev - 0.5) * 10, 0, 10)
            } else if dev < -0.3 {
                tempPenalty = 1   // minor positive signal (deep recovery)
            }
        }

        // SpO2 penalty.
        var spo2Penalty = 0.0
        if weights.includeSpo2, let s = i.spo2Avg {
            switch s {
            case 96...:      spo2Penalty = 0
            case 94..<96:    spo2Penalty = -5
            case 90..<94:    spo2Penalty = -15
            default:         spo2Penalty = -25
            }
        }

        let score = Stats.clamp(base + tempPenalty + spo2Penalty, 0, 100)
        return RecoveryResult(score: score, zone: RecoveryZone(score: score),
                              hrvScore: hrvScore, rhrScore: rhrScore,
                              respScore: respScore, sleepScore: sleepScore,
                              tempPenalty: tempPenalty, spo2Penalty: spo2Penalty)
    }
}
