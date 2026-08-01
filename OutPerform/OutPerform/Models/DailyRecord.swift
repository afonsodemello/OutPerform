//
//  DailyRecord.swift
//  OutPerform
//
//  One persisted SwiftData record per day, holding the raw nightly
//  aggregates and every computed score. The engine writes these; the UI
//  and baseline calculations read them back.
//

import Foundation
import SwiftData

@Model
final class DailyRecord {
    /// Start-of-day (local) the record belongs to. Unique per day.
    var date: Date = Date()

    // Raw nightly aggregates ---------------------------------------------
    var rmssd: Double?
    var sdnn: Double?
    /// Canonical HRV signal used for all scoring (RMSSD when available from a
    /// beat-to-beat series, otherwise SDNN). Kept separate so baselines stay
    /// consistent even when the underlying metric source varies night to night.
    var hrv: Double?
    var dfaAlpha1: Double?
    var restingHR: Double?
    var respiratoryRate: Double?
    var spo2Avg: Double?
    var spo2Min: Double?
    var skinTempC: Double?

    // Sleep --------------------------------------------------------------
    var totalSleepMin: Double?
    var timeInBedMin: Double?
    var remMin: Double?
    var deepMin: Double?
    var coreMin: Double?
    var awakeMin: Double?
    var sleepEfficiency: Double?
    var restorativePct: Double?
    var wakeEvents: Int?
    var sleepOnset: Date?
    var sleepWake: Date?

    // Strain / load ------------------------------------------------------
    var dayStrain: Double?
    var activityStrain: Double?
    var dayTRIMP: Double?
    var acwr: Double?
    var monotony: Double?

    // Scores -------------------------------------------------------------
    var recovery: Double?
    var sleepPerformance: Double?
    var stress: Double?
    var readiness: Double?
    var vo2Max: Double?

    // Sleep need ---------------------------------------------------------
    /// Need for the night that followed this day (driven by this day's strain).
    /// For "today" this is the live "Need tonight" shown in the planner.
    var sleepNeedMin: Double?
    var sleepDebtMin: Double?

    // Apnea screening ----------------------------------------------------
    var odi: Double?

    // Cognitive readiness ------------------------------------------------
    /// Predicted peak cognitive-readiness score for the day (0–100), stored so it
    /// can appear in Trends. The live, time-of-day value is computed on the fly.
    var cognitiveReadiness: Double?

    // Personalisation ----------------------------------------------------
    /// Daily subjective check-in (1–5) used to learn personalised weights.
    var feltGood: Int?

    init(date: Date) {
        self.date = date
    }

    var recoveryZone: RecoveryZone? { recovery.map(RecoveryZone.init(score:)) }
    var strainZone: StrainZone? { dayStrain.map(StrainZone.init(strain:)) }
}
