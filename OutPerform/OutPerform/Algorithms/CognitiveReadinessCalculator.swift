//
//  CognitiveReadinessCalculator.swift
//  OutPerform
//
//  Predicts mental/cognitive readiness — how "locked in" you can be — over the
//  course of a day, and finds your peak deep-work windows.
//
//  The backbone is the Three-Process Model of Alertness (Åkerstedt & Folkard),
//  which sums three published components:
//    • Process S — homeostatic sleep pressure: alertness decays exponentially the
//      longer you've been awake; its starting level depends on how well you slept.
//    • Process C — the circadian rhythm: a ~24 h oscillation (plus a second
//      harmonic for the early-afternoon dip) peaking late afternoon.
//    • Process W — sleep inertia: grogginess right after waking that clears within
//      an hour or so.
//  We then modulate the level (not the daily shape) with autonomic state — HRV
//  deviation from your baseline (neurovisceral-integration link to executive
//  function) and the existing stress score — and a small physical-fatigue term.
//
//  This is a PREDICTION, not a measurement. The optional reaction-time test
//  (`measuredAlertness`) provides ground truth used to calibrate it per person.
//

import Foundation

public struct CognitiveInputs: Sendable {
    /// When the person woke this morning.
    public var wakeTime: Date
    /// Last night's total sleep (minutes).
    public var priorSleepMin: Double
    /// Accumulated sleep debt (minutes, ≥0).
    public var sleepDebtMin: Double
    /// Habitual sleep midpoint as an hour-of-day (0–24) — drives chronotype shift.
    /// e.g. asleep 23:00–07:00 → midpoint 03:00 → 3.0. nil ⇒ average chronotype.
    public var habitualSleepMidpoint: Double?
    /// Today's HRV vs personal baseline, as a z-score (nil if not calibrated).
    public var hrvZ: Double?
    /// Today's stress score 0–100 (nil if not available).
    public var stress: Double?
    /// Today's physical day-strain 0–21 (nil if none yet).
    public var dayStrain: Double?
    /// Personal calibration offset learned from reaction-time tests (added to the
    /// final score, clamped). 0 until the user has taken tests.
    public var calibrationOffset: Double

    /// Hours by which to shift the circadian acrophase — learned from "Feeling
    /// focused / energetic" taps in the Perform tab. Positive = peak later.
    public var circadianPeakShift: Double

    public init(wakeTime: Date, priorSleepMin: Double, sleepDebtMin: Double,
                habitualSleepMidpoint: Double? = nil, hrvZ: Double? = nil,
                stress: Double? = nil, dayStrain: Double? = nil,
                calibrationOffset: Double = 0, circadianPeakShift: Double = 0) {
        self.wakeTime = wakeTime
        self.priorSleepMin = priorSleepMin
        self.sleepDebtMin = sleepDebtMin
        self.habitualSleepMidpoint = habitualSleepMidpoint
        self.hrvZ = hrvZ
        self.stress = stress
        self.dayStrain = dayStrain
        self.calibrationOffset = calibrationOffset
        self.circadianPeakShift = circadianPeakShift
    }
}

public struct CognitiveDrivers: Sendable {
    public var sleepPressure: Double   // 0–100 (Process S contribution)
    public var circadian: Double       // 0–100 (Process C contribution at the time)
    public var recoveryState: Double   // 0–100 (HRV-based)
    public var calm: Double            // 0–100 (inverse of stress)
    public var sleepInertia: Double    // 0–100 (100 = fully cleared)
}

public struct FocusWindow: Sendable {
    public var start: Date
    public var end: Date
    public var peakScore: Double
}

public enum CognitiveReadinessCalculator {

    // MARK: Tunables (documented, defensible defaults)

    /// Circadian acrophase (hour of peak alertness) for an average chronotype.
    static let circadianPeakHour = 16.5
    /// Population-average habitual sleep midpoint (≈03:30) used to derive how much
    /// an individual's circadian phase is shifted earlier/later.
    static let referenceSleepMidpoint = 3.5
    /// Homeostatic decay time-constant (hours) — sleep pressure builds over a day.
    static let homeostaticTau = 12.0
    /// Sleep-inertia time-constant (hours) and how long it meaningfully lasts.
    static let inertiaTau = 0.45

    // MARK: Components

    /// Process C — circadian alertness, normalised to roughly −1…+1.
    /// Primary 24 h cosine peaking at the (chronotype-shifted) acrophase, plus a
    /// 12 h second harmonic that produces the early-afternoon dip.
    public static func circadianComponent(hourOfDay t: Double, midpoint: Double?,
                                          extraShift: Double = 0) -> Double {
        let shift = (midpoint ?? referenceSleepMidpoint) - referenceSleepMidpoint + extraShift
        let peak = circadianPeakHour + shift
        let primary = cos(2 * .pi * (t - peak) / 24)
        // Second harmonic peaks ~6 h before the main peak → post-lunch dip.
        let secondary = 0.4 * cos(2 * .pi * 2 * (t - (peak - 3)) / 24)
        return primary + secondary
    }

    /// Process S — homeostatic alertness given hours awake and how rested you are.
    /// Returns roughly 0…1. Starts high after good sleep and decays exponentially.
    public static func homeostaticComponent(hoursAwake: Double, priorSleepMin: Double,
                                            sleepDebtMin: Double) -> Double {
        let h = max(0, hoursAwake)
        // Sleep sufficiency 0…1 from last night vs an 8 h target, penalised by debt.
        let nightFraction = Stats.clamp(priorSleepMin / 480.0, 0, 1)
        let debtPenalty = Stats.clamp(sleepDebtMin / 480.0, 0, 0.6)   // up to −0.6
        let startLevel = Stats.clamp(0.55 + 0.45 * nightFraction - debtPenalty, 0.1, 1.0)
        let floor = 0.15
        return floor + (startLevel - floor) * exp(-h / homeostaticTau)
    }

    /// Process W — sleep inertia multiplier 0…1 (1 = fully cleared).
    public static func inertiaClearance(hoursAwake: Double) -> Double {
        let h = max(0, hoursAwake)
        return 1 - 0.45 * exp(-h / inertiaTau)
    }

    // MARK: Combined score

    /// Predicted cognitive readiness (0–100) at `time`.
    public static func readiness(at time: Date, inputs: CognitiveInputs,
                                 calendar: Calendar = .current) -> Double {
        let t = hourOfDay(time, calendar: calendar)
        let hoursAwake = time.timeIntervalSince(inputs.wakeTime) / 3600

        let s = homeostaticComponent(hoursAwake: hoursAwake,
                                     priorSleepMin: inputs.priorSleepMin,
                                     sleepDebtMin: inputs.sleepDebtMin)        // 0…1
        let c = circadianComponent(hourOfDay: t, midpoint: inputs.habitualSleepMidpoint,
                                   extraShift: inputs.circadianPeakShift) // −1.4…+1.4
        let w = inertiaClearance(hoursAwake: hoursAwake)                  // 0…1

        // Blend S and C into a base alertness, gate by sleep inertia.
        // Weights: homeostatic dominant, circadian meaningful modulator.
        let base = (0.62 * s + 0.38 * ((c + 1.4) / 2.8))   // both normalised to 0…1
        var score = 100 * base * w

        // Autonomic modulators (level shift, modest).
        if let z = inputs.hrvZ {
            score += 6 * Stats.clamp(z, -2, 2)             // ±12 max
        }
        if let stress = inputs.stress {
            score -= 0.20 * (stress - 50)                  // ±10 max
        }
        // Physical fatigue spills into mental fatigue, more so as the day wears on.
        if let strain = inputs.dayStrain, strain > 12 {
            score -= min(8, (strain - 12) * 1.2) * Stats.clamp(hoursAwake / 10, 0, 1)
        }

        score += inputs.calibrationOffset
        return Stats.clamp(score, 0, 100)
    }

    public static func drivers(at time: Date, inputs: CognitiveInputs,
                               calendar: Calendar = .current) -> CognitiveDrivers {
        let t = hourOfDay(time, calendar: calendar)
        let hoursAwake = time.timeIntervalSince(inputs.wakeTime) / 3600
        let s = homeostaticComponent(hoursAwake: hoursAwake, priorSleepMin: inputs.priorSleepMin,
                                     sleepDebtMin: inputs.sleepDebtMin)
        let c = circadianComponent(hourOfDay: t, midpoint: inputs.habitualSleepMidpoint,
                                   extraShift: inputs.circadianPeakShift)
        return CognitiveDrivers(
            sleepPressure: 100 * s,
            circadian: 100 * (c + 1.4) / 2.8,
            recoveryState: Stats.clamp(50 + 20 * (inputs.hrvZ ?? 0), 0, 100),
            calm: Stats.clamp(100 - (inputs.stress ?? 50), 0, 100),
            sleepInertia: 100 * inertiaClearance(hoursAwake: hoursAwake))
    }

    // MARK: Day curve & peak windows

    /// Samples the readiness curve across [from, to] at `stepMinutes`.
    public static func curve(from: Date, to: Date, stepMinutes: Int = 15,
                             inputs: CognitiveInputs, calendar: Calendar = .current) -> [(time: Date, score: Double)] {
        guard to > from else { return [] }
        var out: [(Date, Double)] = []
        let step = TimeInterval(stepMinutes * 60)
        var t = from
        while t <= to {
            out.append((t, readiness(at: t, inputs: inputs, calendar: calendar)))
            t = t.addingTimeInterval(step)
        }
        return out
    }

    /// Contiguous windows where readiness is in your top band today — the periods
    /// worth protecting for deep work. Threshold = max(absolute 65, 90% of day max).
    public static func peakWindows(curve: [(time: Date, score: Double)],
                                   minMinutes: Int = 45) -> [FocusWindow] {
        guard let dayMax = curve.map(\.score).max(), dayMax > 0 else { return [] }
        let threshold = Swift.max(65.0, dayMax * 0.9)
        var windows: [FocusWindow] = []
        var runStart: Date?
        var runPeak = 0.0
        var lastTime: Date?
        for point in curve {
            if point.score >= threshold {
                if runStart == nil { runStart = point.time; runPeak = point.score }
                runPeak = Swift.max(runPeak, point.score)
                lastTime = point.time
            } else if let start = runStart, let end = lastTime {
                appendWindow(&windows, start: start, end: end, peak: runPeak, minMinutes: minMinutes)
                runStart = nil; runPeak = 0
            }
        }
        if let start = runStart, let end = lastTime {
            appendWindow(&windows, start: start, end: end, peak: runPeak, minMinutes: minMinutes)
        }
        return windows
    }

    private static func appendWindow(_ windows: inout [FocusWindow], start: Date, end: Date,
                                     peak: Double, minMinutes: Int) {
        if end.timeIntervalSince(start) >= TimeInterval(minMinutes * 60) {
            windows.append(FocusWindow(start: start, end: end, peakScore: peak))
        }
    }

    // MARK: Workout / physical-readiness curve

    /// Physical readiness for training (0–100) at `time`.
    ///
    /// Unlike cognitive readiness, physical performance follows core body
    /// temperature, which peaks around 5–7 PM (≈1–2 h after the cognitive
    /// acrophase). No sleep-inertia component — muscles respond differently from
    /// cognition. Chronotype-shifted by the same midpoint-based heuristic, plus
    /// any user-feedback shift stored in `inputs.circadianPeakShift`.
    public static func workoutReadiness(at time: Date, inputs: CognitiveInputs,
                                        calendar: Calendar = .current) -> Double {
        let t = hourOfDay(time, calendar: calendar)
        let hoursAwake = time.timeIntervalSince(inputs.wakeTime) / 3600

        // Physical circadian peak: ~1 h later than the cognitive peak, same chronotype shift.
        let chronotypeShift = (inputs.habitualSleepMidpoint ?? referenceSleepMidpoint)
                              - referenceSleepMidpoint + inputs.circadianPeakShift
        let physicalPeak = circadianPeakHour + 1.0 + chronotypeShift
        let diff = circularHourDiff(t, physicalPeak)
        let circadian = exp(-diff * diff / 22.0)  // Gaussian with σ ≈ 4.7 h

        // Need ~2 h awake before exercising well.
        let warmup = Stats.clamp(hoursAwake / 2.0, 0, 1)

        // Sleep quality penalty.
        let sleepFraction = Stats.clamp(inputs.priorSleepMin / 420.0, 0.45, 1.0)
        let debtPenalty   = Stats.clamp(inputs.sleepDebtMin / 360.0, 0, 0.35)
        let sleepFactor   = Stats.clamp(sleepFraction - debtPenalty, 0.2, 1.0)

        var score = 100.0 * circadian * warmup * sleepFactor

        // Accumulated strain already today reduces physical readiness.
        if let strain = inputs.dayStrain { score -= Stats.clamp(strain / 21.0, 0, 0.5) * 25 }

        // Low HRV suppresses physical readiness (autonomic link to performance).
        if let z = inputs.hrvZ, z < 0 { score += 5 * Stats.clamp(z, -2, 0) }

        return Stats.clamp(score, 0, 100)
    }

    /// Samples the workout readiness curve across [from, to] at `stepMinutes`.
    public static func workoutCurve(from: Date, to: Date, stepMinutes: Int = 15,
                                    inputs: CognitiveInputs,
                                    calendar: Calendar = .current) -> [(time: Date, score: Double)] {
        guard to > from else { return [] }
        var out: [(Date, Double)] = []
        let step = TimeInterval(stepMinutes * 60)
        var t = from
        while t <= to {
            out.append((t, workoutReadiness(at: t, inputs: inputs, calendar: calendar)))
            t = t.addingTimeInterval(step)
        }
        return out
    }

    /// Contiguous windows where workout readiness is high — the best training slots.
    public static func bestWorkoutWindows(curve: [(time: Date, score: Double)],
                                          minMinutes: Int = 30) -> [FocusWindow] {
        guard let dayMax = curve.map(\.score).max(), dayMax > 0 else { return [] }
        let threshold = Swift.max(55.0, dayMax * 0.88)
        var windows: [FocusWindow] = []
        var runStart: Date?
        var runPeak = 0.0
        var lastTime: Date?
        for point in curve {
            if point.score >= threshold {
                if runStart == nil { runStart = point.time; runPeak = point.score }
                runPeak = Swift.max(runPeak, point.score)
                lastTime = point.time
            } else if let start = runStart, let end = lastTime {
                appendWindow(&windows, start: start, end: end, peak: runPeak, minMinutes: minMinutes)
                runStart = nil; runPeak = 0
            }
        }
        if let start = runStart, let end = lastTime {
            appendWindow(&windows, start: start, end: end, peak: runPeak, minMinutes: minMinutes)
        }
        return windows
    }

    /// Circular difference between two hours-of-day (handles midnight wrapping).
    private static func circularHourDiff(_ a: Double, _ b: Double) -> Double {
        var d = a - b
        while d > 12  { d -= 24 }
        while d < -12 { d += 24 }
        return d
    }

    // MARK: Reaction-time (PVT-style) test → measured alertness

    /// Maps a reaction-time test to a 0–100 measured-alertness score.
    /// Rested mean RT is ~230–260 ms; lapses (RT > 500 ms) rise sharply with sleep
    /// loss, so they're penalised directly.
    public static func measuredAlertness(meanReactionMs: Double, lapses: Int) -> Double {
        let rtScore = 100 - (meanReactionMs - 230) * 0.35
        let penalty = Double(lapses) * 4
        return Stats.clamp(rtScore - penalty, 0, 100)
    }

    /// Updates the personal calibration offset toward (measured − predicted) using
    /// an exponential moving average, so calibration is gradual and robust to noise.
    public static func updatedCalibrationOffset(previous: Double, predictedAtTest: Double,
                                                measured: Double, alpha: Double = 0.3) -> Double {
        let target = measured - predictedAtTest
        let blended = previous + alpha * (target - previous)
        return Stats.clamp(blended, -25, 25)
    }

    // MARK: Helpers

    public static func hourOfDay(_ date: Date, calendar: Calendar = .current) -> Double {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
    }
}

public enum FocusZone: String, Sendable {
    case low, moderate, high, peak

    public nonisolated init(score: Double) {
        switch score {
        case ..<40:  self = .low
        case ..<65:  self = .moderate
        case ..<82:  self = .high
        default:     self = .peak
        }
    }

    public var label: String {
        switch self {
        case .low:      return "Low — light/admin work"
        case .moderate: return "Moderate — steady tasks"
        case .high:     return "High — focused work"
        case .peak:     return "Peak — deep work"
        }
    }

    public var shortLabel: String {
        switch self {
        case .low: return "Low"; case .moderate: return "Moderate"
        case .high: return "High"; case .peak: return "Peak"
        }
    }
}
