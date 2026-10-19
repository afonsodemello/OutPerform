//
//  AppSettings.swift
//  OutPerform
//
//  User profile + app preferences, backed by UserDefaults. Drives onboarding,
//  the active data source, and the bedtime planner.
//

import Foundation
import Observation

public enum DataSourceType: String, CaseIterable, Sendable, Codable {
    case appleHealth
    case googleHealth
    case bluetooth
    case combined
    case demo

    public var displayName: String {
        switch self {
        case .appleHealth:  return "Apple Health"
        case .googleHealth: return "Google Health"
        case .bluetooth:    return "Bluetooth band"
        case .combined:     return "All sources"
        case .demo:         return "Demo"
        }
    }

    public var detail: String {
        switch self {
        case .appleHealth:
            return "Reads directly from Apple Health on this iPhone (HealthKit). Best if your wearable already syncs to Health."
        case .googleHealth:
            return "Sign in with your Google account to read your heart rate, sleep and activity from Google Health."
        case .bluetooth:
            return "Pairs directly with a Bluetooth heart-rate band or chest strap. Heart rate and heartbeats are recorded on this iPhone and every score is computed here — no account needed."
        case .combined:
            return "Uses Apple Health, Google Health and your Bluetooth band at the same time. Each piece of data comes from whichever source has it first and best, so syncs fill in faster and gaps in one source are covered by another."
        case .demo:
            return "Explore OutPerform with 30 days of sample data — no wearable required. Switching to a real source will clear all demo data."
        }
    }

    public var systemImage: String {
        switch self {
        case .appleHealth:  return "heart.fill"
        case .googleHealth: return "g.circle.fill"
        case .bluetooth:    return "dot.radiowaves.left.and.right"
        case .combined:     return "square.stack.3d.up.fill"
        case .demo:         return "sparkles"
        }
    }
}

extension DataSourceType {
    /// Sources that talk to the Bluetooth band.
    public var usesBand: Bool { self == .bluetooth || self == .combined }
}

@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: Onboarding / source

    var hasOnboarded: Bool {
        didSet { defaults.set(hasOnboarded, forKey: "hasOnboarded") }
    }

    var dataSource: DataSourceType {
        didSet { defaults.set(dataSource.rawValue, forKey: "dataSource") }
    }

    // MARK: Profile

    /// Date of birth. Age (used for the max-HR formula) is derived from it.
    var birthDate: Date {
        didSet { defaults.set(birthDate.timeIntervalSince1970, forKey: "birthDate") }
    }

    /// Current age in whole years, clamped to a sensible range.
    var age: Int {
        let years = Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year ?? 30
        return min(120, max(13, years))
    }

    var biologicalSex: BiologicalSex {
        didSet { defaults.set(biologicalSex.rawValue, forKey: "biologicalSex") }
    }

    /// Which sources "All sources" draws from (each must also be ready:
    /// Google signed in, band paired).
    var combinedSources: Set<SourceKind> {
        didSet { defaults.set(combinedSources.map(\.rawValue), forKey: "combinedSources") }
    }

    /// Body weight and height, used for calorie estimates (Keytel / Harris–Benedict).
    var weightKg: Double {
        didSet { defaults.set(weightKg, forKey: "weightKg") }
    }

    var heightCm: Double {
        didSet { defaults.set(heightCm, forKey: "heightCm") }
    }

    /// Desired wake time stored as minutes-after-midnight.
    var wakeMinuteOfDay: Int {
        didSet { defaults.set(wakeMinuteOfDay, forKey: "wakeMinuteOfDay") }
    }

    var sleepLatencyMin: Double {
        didSet { defaults.set(sleepLatencyMin, forKey: "sleepLatencyMin") }
    }

    var performanceTarget: SleepNeedCalculator.PerformanceTarget {
        didSet { defaults.set(performanceTarget.rawValue, forKey: "performanceTarget") }
    }

    /// Date of first launch — used to gate provisional vs full scores.
    var firstLaunch: Date {
        didSet { defaults.set(firstLaunch.timeIntervalSince1970, forKey: "firstLaunch") }
    }

    /// Personal calibration offset for the cognitive-readiness prediction, learned
    /// from reaction-time tests (added to the predicted score, clamped ±25).
    var focusCalibrationOffset: Double {
        didSet { defaults.set(focusCalibrationOffset, forKey: "focusCalibrationOffset") }
    }

    /// Hours by which the user's reported focus peak differs from the algorithm's
    /// prediction — learned via EMA from "Feeling focused" taps. Positive = user
    /// peaks later than predicted; shifts the circadian acrophase forward.
    var focusFeedbackShift: Double {
        didSet { defaults.set(focusFeedbackShift, forKey: "focusFeedbackShift") }
    }

    /// Same idea for physical energy / workout readiness.
    var energyFeedbackShift: Double {
        didSet { defaults.set(energyFeedbackShift, forKey: "energyFeedbackShift") }
    }

    /// How many daily "time to sync" push notifications to send. 0 = off, default 3.
    var syncReminderCount: Int {
        didSet { defaults.set(syncReminderCount, forKey: "syncReminderCount") }
    }

    private init() {
        hasOnboarded = defaults.bool(forKey: "hasOnboarded")
        dataSource = DataSourceType(rawValue: defaults.string(forKey: "dataSource") ?? "") ?? .appleHealth
        // Birth date, migrating from a previously-stored age if needed.
        let cal = Calendar.current
        if let t = defaults.object(forKey: "birthDate") as? Double {
            birthDate = Date(timeIntervalSince1970: t)
        } else {
            let storedAge = defaults.integer(forKey: "age")
            let years = storedAge == 0 ? 30 : storedAge
            birthDate = cal.date(byAdding: .year, value: -years, to: Date()) ?? Date()
        }
        biologicalSex = BiologicalSex(rawValue: defaults.string(forKey: "biologicalSex") ?? "") ?? .other
        combinedSources = Set((defaults.stringArray(forKey: "combinedSources") ?? SourceKind.allCases.map(\.rawValue))
            .compactMap(SourceKind.init(rawValue:)))
        weightKg = defaults.object(forKey: "weightKg") as? Double ?? 75
        heightCm = defaults.object(forKey: "heightCm") as? Double ?? 175
        let storedWake = defaults.object(forKey: "wakeMinuteOfDay") as? Int
        wakeMinuteOfDay = storedWake ?? (7 * 60)   // 07:00
        let storedLatency = defaults.object(forKey: "sleepLatencyMin") as? Double
        sleepLatencyMin = storedLatency ?? 15
        performanceTarget = SleepNeedCalculator.PerformanceTarget(
            rawValue: defaults.string(forKey: "performanceTarget") ?? "") ?? .peak
        focusCalibrationOffset = defaults.double(forKey: "focusCalibrationOffset")
        focusFeedbackShift = defaults.double(forKey: "focusFeedbackShift")
        energyFeedbackShift = defaults.double(forKey: "energyFeedbackShift")
        syncReminderCount = defaults.object(forKey: "syncReminderCount") as? Int ?? 3
        if let t = defaults.object(forKey: "firstLaunch") as? Double {
            firstLaunch = Date(timeIntervalSince1970: t)
        } else {
            let now = Date()
            firstLaunch = now
            defaults.set(now.timeIntervalSince1970, forKey: "firstLaunch")
        }
    }

    // MARK: Derived

    /// Days of data collected since first launch.
    var daysSinceFirstLaunch: Int {
        Calendar.current.dateComponents([.day], from: firstLaunch, to: Date()).day ?? 0
    }

    /// Calibration phase.
    enum CalibrationPhase { case collecting, provisional, full, personalised }
    var calibrationPhase: CalibrationPhase {
        switch daysSinceFirstLaunch {
        case ..<7:   return .collecting
        case ..<14:  return .provisional
        case ..<30:  return .full
        default:     return .personalised
        }
    }

    /// Today's desired wake time as an absolute Date (tomorrow morning if past).
    func desiredWakeDate(reference: Date = Date()) -> Date {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: reference)
        let wake = cal.date(byAdding: .minute, value: wakeMinuteOfDay, to: startOfDay)!
        return wake > reference ? wake : cal.date(byAdding: .day, value: 1, to: wake)!
    }
}
