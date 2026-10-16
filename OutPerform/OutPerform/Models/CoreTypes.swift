//
//  CoreTypes.swift
//  OutPerform
//
//  Source-agnostic value types shared by the health providers and the
//  scoring algorithms. Nothing here depends on HealthKit, SwiftUI or
//  SwiftData, so the algorithm layer can be unit-tested in isolation.
//

import Foundation

// MARK: - Raw samples

/// A single numeric sample over a time interval (HR bpm, HRV ms, SpO2 fraction, °C, …).
/// The `value` is always expressed in the canonical unit documented at the call site.
nonisolated public struct QuantitySample: Sendable, Hashable {
    public var start: Date
    public var end: Date
    public var value: Double

    public init(start: Date, end: Date, value: Double) {
        self.start = start
        self.end = end
        self.value = value
    }

    public init(date: Date, value: Double) {
        self.start = date
        self.end = date
        self.value = value
    }

    public var midpoint: Date { start.addingTimeInterval(end.timeIntervalSince(start) / 2) }
    public var durationMinutes: Double { max(0, end.timeIntervalSince(start)) / 60.0 }
}

// MARK: - Sleep

nonisolated public enum SleepStage: String, Sendable, Codable, CaseIterable {
    case inBed
    case awake
    case core          // Light / N1-N2
    case deep          // Slow-wave / N3
    case rem
    case asleepUnspecified

    /// Stages that count as actual sleep (everything except awake / inBed).
    public var isAsleep: Bool {
        switch self {
        case .awake, .inBed: return false
        case .core, .deep, .rem, .asleepUnspecified: return true
        }
    }

    /// Restorative sleep = REM + Deep (per).
    public var isRestorative: Bool { self == .rem || self == .deep }
}

nonisolated public struct SleepSegment: Sendable, Hashable {
    public var start: Date
    public var end: Date
    public var stage: SleepStage

    public init(start: Date, end: Date, stage: SleepStage) {
        self.start = start
        self.end = end
        self.stage = stage
    }

    public var durationMinutes: Double { max(0, end.timeIntervalSince(start)) / 60.0 }
}

// MARK: - Workouts

/// Activity types we care about for the muscular-load multiplier.
nonisolated public enum WorkoutActivity: String, Sendable, Codable, CaseIterable {
    case weightlifting
    case hiit
    case yoga
    case running
    case cycling
    case walking
    case other

    /// Muscular-load multiplier applied to activity strain only.
    public var muscularLoadMultiplier: Double {
        switch self {
        case .weightlifting: return 1.3
        case .hiit:          return 1.2
        case .yoga:          return 1.1
        case .running, .cycling, .walking: return 1.0
        case .other:         return 1.0
        }
    }

    public var displayName: String {
        switch self {
        case .weightlifting: return "Strength"
        case .hiit:          return "HIIT / CrossFit"
        case .yoga:          return "Yoga / Pilates"
        case .running:       return "Running"
        case .cycling:       return "Cycling"
        case .walking:       return "Walking"
        case .other:         return "Workout"
        }
    }
}

nonisolated public struct WorkoutSession: Sendable, Hashable {
    public var start: Date
    public var end: Date
    public var activity: WorkoutActivity
    public var heartRates: [QuantitySample]
    public var activeEnergyKcal: Double?

    public init(start: Date, end: Date, activity: WorkoutActivity,
                heartRates: [QuantitySample] = [], activeEnergyKcal: Double? = nil) {
        self.start = start
        self.end = end
        self.activity = activity
        self.heartRates = heartRates
        self.activeEnergyKcal = activeEnergyKcal
    }

    public var durationMinutes: Double { max(0, end.timeIntervalSince(start)) / 60.0 }
}

// MARK: - Biological sex

nonisolated public enum BiologicalSex: String, Sendable, Codable, CaseIterable {
    case male
    case female
    case other

    public var displayName: String {
        switch self {
        case .male: return "Male"
        case .female: return "Female"
        case .other: return "Other / Prefer not to say"
        }
    }
}

// MARK: - Score zones

nonisolated public enum RecoveryZone: String, Sendable {
    case red, yellow, green

    public nonisolated init(score: Double) {
        switch score {
        case ..<34:  self = .red
        case ..<67:  self = .yellow
        default:     self = .green
        }
    }

    public var label: String {
        switch self {
        case .green:  return "Primed to perform"
        case .yellow: return "Moderate strain OK"
        case .red:    return "Rest recommended"
        }
    }
}

nonisolated public enum StrainZone: String, Sendable {
    case light, moderate, high, allOut

    public nonisolated init(strain: Double) {
        switch strain {
        case ..<10: self = .light
        case ..<14: self = .moderate
        case ..<18: self = .high
        default:    self = .allOut
        }
    }

    public var label: String {
        switch self {
        case .light:    return "Active recovery"
        case .moderate: return "Maintain fitness"
        case .high:     return "Fitness stimulus"
        case .allOut:   return "All out — needs recovery"
        }
    }
}

nonisolated public enum ACWRZone: String, Sendable {
    case undertraining, sweetSpot, caution, highRisk

    public nonisolated init(ratio: Double) {
        switch ratio {
        case ..<0.8:  self = .undertraining
        case ..<1.3:  self = .sweetSpot
        case ..<1.5:  self = .caution
        default:      self = .highRisk
        }
    }

    public var label: String {
        switch self {
        case .undertraining: return "Undertraining"
        case .sweetSpot:     return "Sweet spot"
        case .caution:       return "Caution — load spiked"
        case .highRisk:      return "High load — consider rest"
        }
    }
}

nonisolated public enum Chronotype: String, Sendable, Codable {
    case earlyBird, neutral, nightOwl

    public var displayName: String {
        switch self {
        case .earlyBird: return "Early bird"
        case .neutral:   return "Neutral"
        case .nightOwl:  return "Night owl"
        }
    }
}

nonisolated public enum ApneaRisk: String, Sendable {
    case normal, mild, moderate, severe

    public nonisolated init(odi: Double) {
        switch odi {
        case ..<5:  self = .normal
        case ..<15: self = .mild
        case ..<30: self = .moderate
        default:    self = .severe
        }
    }

    public var label: String {
        switch self {
        case .normal:   return "Normal"
        case .mild:     return "Mild — monitor"
        case .moderate: return "Moderate — see a doctor"
        case .severe:   return "Severe — seek evaluation"
        }
    }
}
