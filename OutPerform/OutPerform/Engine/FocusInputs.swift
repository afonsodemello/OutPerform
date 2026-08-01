//
//  FocusInputs.swift
//  OutPerform
//
//  Builds `CognitiveInputs` for the cognitive-readiness model from stored daily
//  records + settings. Shared so the engine (daily peak for Trends) and the live
//  Focus screen compute from exactly the same inputs.
//

import Foundation

/// Read-only view of a day's metrics needed to build cognitive-readiness inputs.
/// Both the persisted `DailyRecord` (live Focus screen, main actor) and the plain
/// `Sendable` `DayValues` (off-main batch compute) conform, so the SAME builder
/// runs in both places without dragging SwiftData onto a background thread.
protocol FocusDaySource {
    var date: Date { get }
    var sleepWake: Date? { get }
    var sleepOnset: Date? { get }
    var totalSleepMin: Double? { get }
    var sleepDebtMin: Double? { get }
    var hrv: Double? { get }
    var stress: Double? { get }
    var dayStrain: Double? { get }
}

extension DailyRecord: FocusDaySource {}

enum FocusInputs {

    /// Build inputs for `record` (the day to score), using `history` (other days,
    /// any order) for baselines. Returns nil if the day lacks the minimum data
    /// (we need a sleep estimate to anchor sleep pressure and wake time).
    static func build<Source: FocusDaySource>(
                      for record: Source, history: [Source],
                      wakeMinuteFallback: Int, calibrationOffset: Double,
                      circadianPeakShift: Double = 0,
                      calendar: Calendar = .current) -> CognitiveInputs? {
        let dayStart = calendar.startOfDay(for: record.date)

        // Wake time: prefer the measured wake, else the user's habitual wake time.
        let wakeTime = record.sleepWake
            ?? calendar.date(byAdding: .minute, value: wakeMinuteFallback, to: dayStart)!

        // Need at least a sleep figure for a meaningful prediction.
        guard let priorSleep = record.totalSleepMin, priorSleep > 0 else { return nil }

        // Chronotype: average sleep midpoint over recent nights (incl. this one).
        let recent = ([record] + history).prefix(30)
        let midpoints: [Double] = recent.compactMap { r in
            guard let onset = r.sleepOnset, let wake = r.sleepWake, wake > onset else { return nil }
            let mid = onset.addingTimeInterval(wake.timeIntervalSince(onset) / 2)
            return CognitiveReadinessCalculator.hourOfDay(mid, calendar: calendar)
        }
        let habitualMidpoint = midpoints.isEmpty ? nil : Stats.mean(midpoints)

        // HRV z-score vs the last 14 days (excluding this record).
        var hrvZ: Double?
        if let hrv = record.hrv {
            let baseline = history.compactMap(\.hrv).prefix(14)
            if baseline.count >= 5 {
                let m = Stats.mean(Array(baseline))
                let sd = Stats.stdDev(Array(baseline))
                if sd > 0 { hrvZ = Stats.zScore(hrv, mean: m, std: sd) }
            }
        }

        return CognitiveInputs(
            wakeTime: wakeTime,
            priorSleepMin: priorSleep,
            sleepDebtMin: record.sleepDebtMin ?? 0,
            habitualSleepMidpoint: habitualMidpoint,
            hrvZ: hrvZ,
            stress: record.stress,
            dayStrain: record.dayStrain,
            calibrationOffset: calibrationOffset,
            circadianPeakShift: circadianPeakShift)
    }
}
