//
//  FitnessAgeCalculator.swift
//  OutPerform
//
//  Fitness Age: how your cardiorespiratory fitness compares to the typical
//  person, expressed in years. Not a biological or medical age.
//
//  Method: the HUNT fitness study's non-exercise VO2max model (Nes et al.,
//  Med Sci Sports Exerc 2011; the model behind NTNU's Fitness Age),
//  waist-circumference variant:
//
//    men:   VO2max = 100.27 − 0.296·age + 0.226·PA − 0.369·waist − 0.155·RHR
//    women: VO2max =  74.74 − 0.247·age + 0.198·PA − 0.259·waist − 0.114·RHR
//
//  Fitness Age is the age at which a reference person (resting HR 65 bpm,
//  typical activity) would have your estimated VO2max. Solving the equation
//  for that age, the waist term cancels, so no body measurements are needed:
//
//    fitnessAge = age + (b_RHR·(RHR − 65) − b_PA·(PA − PA_ref)) / b_age
//
//  PA is the HUNT physical-activity index (Kurtze et al. 2008): frequency ×
//  intensity × duration of exercise (0–15), reconstructed from the workouts
//  and training strain the app records instead of a questionnaire.
//
//  The model's error is about ±5 ml/kg/min, roughly ±5 years, so the result
//  is shown as a range and should be read as a trend.
//

import Foundation

nonisolated public enum FitnessAgeCalculator {
    public static let referenceRHR = 65.0
    /// "2–3 times a week, until out of breath, 30–60 min": 2.5 × 2 × 0.75.
    public static let referencePA = 3.75
    public static let bandYears = 5.0
    /// Nights of resting HR needed in the last 7 days.
    public static let minRHRNights = 4
    /// Below this the model can't tell people apart; shown as "18 or younger".
    public static let floorAge = 18.0

    struct Coefficients { let age, pa, rhr: Double }
    static let men = Coefficients(age: 0.296, pa: 0.226, rhr: 0.155)
    static let women = Coefficients(age: 0.247, pa: 0.198, rhr: 0.114)

    // MARK: Activity index

    public enum Intensity: Int, Sendable, Comparable {
        case easy = 1        // "without getting out of breath or sweating"
        case breathless = 2  // "until out of breath and sweating"
        case exhausted = 3   // "near exhaustion"
        public static func < (a: Intensity, b: Intensity) -> Bool { a.rawValue < b.rawValue }

        public var label: String {
            switch self {
            case .easy:       return "easy"
            case .breathless: return "hard"
            case .exhausted:  return "very hard"
            }
        }
    }

    /// One exercise session, from a recorded workout or a day with activity strain.
    public struct Session: Sendable {
        public var minutes: Double
        public var intensity: Intensity
        public init(minutes: Double, intensity: Intensity) {
            self.minutes = minutes; self.intensity = intensity
        }
    }

    public struct ActivityIndex: Sendable {
        public var sessionsPerWeek: Double
        public var typicalMinutes: Double
        public var intensity: Intensity
        public var frequencyScore: Double
        public var durationScore: Double
        public var value: Double { frequencyScore * Double(intensity.rawValue) * durationScore }

        public var summary: String {
            guard sessionsPerWeek > 0 else { return "no workouts tracked" }
            let freq = sessionsPerWeek < 1.5 ? "about once a week"
                : String(format: "%.0f× a week", sessionsPerWeek.rounded())
            return "\(freq), \(intensity.label), ~\(Int(typicalMinutes.rounded())) min"
        }
    }

    /// Activity index from the sessions in the last `days` days.
    public static func activityIndex(sessions: [Session], days: Double = 28) -> ActivityIndex {
        let perWeek = Double(sessions.count) / (days / 7)
        let freq: Double
        switch perWeek {
        case ..<0.5: freq = 0       // never / less than once a week
        case ..<1.5: freq = 1       // once a week
        case ..<4.5: freq = 2.5     // 2–3 times a week
        default:     freq = 5       // nearly every day
        }
        let minutes = sessions.isEmpty ? 0 : Stats.median(sessions.map(\.minutes))
        let dur: Double
        switch minutes {
        case ..<15:  dur = 0.1
        case ..<30:  dur = 0.38
        case ...60:  dur = 0.75
        default:     dur = 1.0
        }
        // The typical (median) session intensity.
        let sorted = sessions.map(\.intensity).sorted()
        let intensity = sorted.isEmpty ? .easy : sorted[sorted.count / 2]
        return ActivityIndex(sessionsPerWeek: perWeek, typicalMinutes: minutes, intensity: intensity,
                             frequencyScore: freq, durationScore: dur)
    }

    // MARK: Fitness age

    public struct Result: Sendable {
        public var fitnessAge: Double
        public var age: Int
        public var restingHR: Double
        public var activity: ActivityIndex
        /// Years added (+) or removed (−) by each input.
        public var rhrYears: Double
        public var activityYears: Double

        public var low: Double { fitnessAge - bandYears }
        public var high: Double { fitnessAge + bandYears }
        public var difference: Double { fitnessAge - Double(age) }
        public var isAtFloor: Bool { fitnessAge <= floorAge }
    }

    public static func compute(age: Int, sex: BiologicalSex, restingHRs: [Double],
                               activity: ActivityIndex) -> Result? {
        guard restingHRs.count >= minRHRNights else { return nil }
        let rhr = Stats.median(restingHRs)
        func years(_ c: Coefficients) -> (Double, Double) {
            (c.rhr * (rhr - referenceRHR) / c.age, -c.pa * (activity.value - referencePA) / c.age)
        }
        let (rY, aY): (Double, Double)
        switch sex {
        case .male:   (rY, aY) = years(men)
        case .female: (rY, aY) = years(women)
        case .other:
            let m = years(men), w = years(women)
            (rY, aY) = ((m.0 + w.0) / 2, (m.1 + w.1) / 2)
        }
        let raw = Double(age) + rY + aY
        // Stay within a plausible span of your real age.
        let fitnessAge = Stats.clamp(raw, floorAge, Double(age) + 25)
        return Result(fitnessAge: fitnessAge, age: age, restingHR: rhr, activity: activity,
                      rhrYears: rY, activityYears: aY)
    }

    // MARK: Other long-term health factors (shown, not part of the number)

    public enum FactorStatus: Sendable { case good, okay, needsWork }

    /// WHO: 150–300 min moderate or 75–150 min vigorous per week (vigorous counts double).
    public static func activityMinutesStatus(moderate: Double, vigorous: Double) -> FactorStatus {
        let equivalent = moderate + 2 * vigorous
        return equivalent >= 150 ? .good : equivalent >= 75 ? .okay : .needsWork
    }

    /// Adults: 7–9 h.
    public static func sleepDurationStatus(averageMinutes: Double) -> FactorStatus {
        switch averageMinutes {
        case 420...540: return .good
        case 390..<420, 540..<600: return .okay
        default: return .needsWork
        }
    }

    /// Spread of bedtimes; regular sleep timing is linked to better long-term health.
    public static func sleepConsistencyStatus(bedtimeSDHours: Double) -> FactorStatus {
        bedtimeSDHours <= 0.5 ? .good : bedtimeSDHours <= 1.0 ? .okay : .needsWork
    }
}
