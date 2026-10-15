//
//  HRWorkoutDetector.swift
//  OutPerform
//
//  Finds workouts after the fact in the stored heart-rate stream, so nothing
//  has to be logged by hand.
//
//  NOOP gates detection on elevated HR AND sustained motion. The Fitbit Air's
//  Bluetooth profile carries no motion data, so this HR-only version
//  compensates by being stricter on the cardiac side:
//   • a minute is "active" when HR ≥ RHR + 40% of heart-rate reserve
//     (and at least RHR + 15 bpm);
//   • active minutes merge across gaps ≤ 2 min (≈ NOOP's 150 s);
//   • a bout must last ≥ 10 min with ≥ 50% of it in Edwards zone 2+
//     (≥ 60% HRR), which rules out stress spikes and stairs.
//
//  Calories: Keytel et al. (2005) HR-based expenditure above
//  RHR + 30% HRR, revised Harris–Benedict BMR below it. Approximate.
//

import Foundation

nonisolated public struct DetectedBout: Sendable {
    public var start: Date
    public var end: Date
    public var avgHR: Double
    public var peakHR: Double
    public var kcal: Double
    public var heartRates: [QuantitySample]
}

nonisolated public struct BodyProfile: Sendable {
    public var age: Int
    public var sex: BiologicalSex
    public var weightKg: Double
    public var heightCm: Double
    public init(age: Int, sex: BiologicalSex, weightKg: Double, heightCm: Double) {
        self.age = age; self.sex = sex; self.weightKg = weightKg; self.heightCm = heightCm
    }
}

nonisolated public enum HRWorkoutDetector {
    public static let hrrFraction = 0.40
    public static let minMarginBPM = 15.0
    public static let mergeGapMin = 2
    public static let minBoutMin = 10
    public static let minZone2PlusShare = 0.50

    /// - Parameter minuteHR: 1-minute mean HR samples (start = minute start).
    /// - Parameter excluding: intervals (e.g. sleep) never counted as exercise.
    public static func detect(minuteHR: [QuantitySample], restingHR: Double, hrMax: Double,
                              profile: BodyProfile, excluding: [DateInterval] = []) -> [DetectedBout] {
        guard hrMax > restingHR, !minuteHR.isEmpty else { return [] }
        let hrr = hrMax - restingHR
        let gate = max(restingHR + hrrFraction * hrr, restingHR + minMarginBPM)
        let sorted = minuteHR.sorted { $0.start < $1.start }
            .filter { s in !excluding.contains { $0.contains(s.start) } }

        var bouts: [[QuantitySample]] = []
        var current: [QuantitySample] = []
        for s in sorted where s.value >= gate {
            if let last = current.last,
               s.start.timeIntervalSince(last.start) > Double(mergeGapMin + 1) * 60 {
                bouts.append(current); current = []
            }
            current.append(s)
        }
        if !current.isEmpty { bouts.append(current) }

        return bouts.compactMap { active in
            guard let first = active.first, let last = active.last else { return nil }
            let start = first.start, end = last.start.addingTimeInterval(60)
            guard end.timeIntervalSince(start) >= Double(minBoutMin) * 60 else { return nil }
            // Use every minute inside the bout (including merged gaps) for stats.
            let all = sorted.filter { $0.start >= start && $0.start < end }
            let z2 = all.filter { ($0.value - restingHR) / hrr >= 0.60 }.count
            guard Double(z2) / Double(max(all.count, 1)) >= minZone2PlusShare else { return nil }
            let kcal = all.reduce(0) { $0 + kcalPerMinute(hr: $1.value, restingHR: restingHR, hrMax: hrMax, profile: profile) }
            return DetectedBout(start: start, end: end,
                                avgHR: Stats.mean(all.map(\.value)),
                                peakHR: all.map(\.value).max() ?? 0,
                                kcal: kcal, heartRates: all)
        }
    }

    /// Energy for one minute at `hr`.
    public static func kcalPerMinute(hr: Double, restingHR: Double, hrMax: Double, profile: BodyProfile) -> Double {
        let restingRate = bmrKcalPerDay(profile) / 1440
        guard hr >= restingHR + 0.30 * (hrMax - restingHR) else { return restingRate }
        let w = profile.weightKg, a = Double(profile.age)
        let kj: Double
        switch profile.sex {
        case .male:   kj = -55.0969 + 0.6309 * hr + 0.1988 * w + 0.2017 * a
        case .female: kj = -20.4022 + 0.4472 * hr - 0.1263 * w + 0.074 * a
        case .other:  kj = ((-55.0969 + 0.6309 * hr + 0.1988 * w + 0.2017 * a)
                            + (-20.4022 + 0.4472 * hr - 0.1263 * w + 0.074 * a)) / 2
        }
        return max(restingRate, kj / 4.184)
    }

    /// Revised Harris–Benedict (Roza & Shizgal 1984).
    public static func bmrKcalPerDay(_ p: BodyProfile) -> Double {
        let w = p.weightKg, h = p.heightCm, a = Double(p.age)
        let male = 88.362 + 13.397 * w + 4.799 * h - 5.677 * a
        let female = 447.593 + 9.247 * w + 3.098 * h - 4.330 * a
        switch p.sex {
        case .male: return male
        case .female: return female
        case .other: return (male + female) / 2
        }
    }
}
