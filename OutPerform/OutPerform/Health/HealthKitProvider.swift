//
//  HealthKitProvider.swift
//  OutPerform
//
//  Apple Health backend. Reads every biometric the app uses and exposes them
//  as source-agnostic samples.
//

import Foundation
import HealthKit
import UIKit

final class HealthKitProvider: HealthDataProvider {
    let sourceType: DataSourceType = .appleHealth
    private let store = HKHealthStore()

    func isAvailable() -> Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: Types we read

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.respiratoryRate),
            HKQuantityType(.oxygenSaturation),
            HKQuantityType(.vo2Max),
            HKQuantityType(.activeEnergyBurned),
            HKCategoryType(.sleepAnalysis),
            HKSeriesType.heartbeat(),          // beat-to-beat RR for true HRV
            HKObjectType.workoutType()
        ]
        if #available(iOS 16.0, *) {
            types.insert(HKQuantityType(.appleSleepingWristTemperature))
        }
        return types
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthDataError.notAvailable }
        let store = store, types = readTypes
        // Queued behind any other permission popup, or iOS drops this sheet.
        try await PermissionGate.shared.run {
            try await store.requestAuthorization(toShare: [], read: types)
        }
        // Only trust it once Apple confirms the question was really asked.
        Self.authorizationRequested = !(await needsAuthorization())
    }

    // MARK: Authorization guard

    /// Set once Apple's permission sheet has been shown for every type we read
    /// (this launch). Shared by every HealthKitProvider instance.
    private static var authorizationRequested = false
    private static var authorizationTask: Task<Void, Error>?

    /// True when Apple Health has never been asked about some type we read.
    /// (Apple never reveals whether *read* access was granted, only whether
    /// the question has been asked.)
    func needsAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        let status = try? await store.statusForAuthorizationRequest(toShare: [], read: readTypes)
        return status != .unnecessary
    }

    /// Every query calls this first. Querying a type nobody has asked about
    /// fails with "Authorization not determined", which used to happen on any
    /// path that synced without going through onboarding or the Settings
    /// source picker. Asks once (concurrent queries share the request); in the
    /// background, where the sheet can't show, Apple Health sits this sync out.
    func ensureAuthorized() async throws {
        if Self.authorizationRequested { return }
        if let pending = Self.authorizationTask { return try await pending.value }
        // One shared task, registered before any await, so the parallel
        // queries of a sync don't each start their own request.
        let task = Task { () throws in
            guard await self.needsAuthorization() else { return }
            // "inactive" while the app is launching is fine; only a real
            // background sync can't show the sheet.
            guard UIApplication.shared.applicationState != .background else {
                throw HealthDataError.network("Apple Health needs permission — open OutPerform to allow it.")
            }
            try await self.requestAuthorization()
        }
        Self.authorizationTask = task
        defer { Self.authorizationTask = nil }
        try await task.value
    }

    // MARK: Generic quantity query

    private func quantitySamples(_ type: HKQuantityType, unit: HKUnit,
                                 from: Date, to: Date) async throws -> [QuantitySample] {
        try await ensureAuthorized()
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        return try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: sort) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                let result = (samples as? [HKQuantitySample] ?? []).map {
                    QuantitySample(start: $0.startDate, end: $0.endDate, value: $0.quantity.doubleValue(for: unit))
                }
                cont.resume(returning: result)
            }
            store.execute(q)
        }
    }

    /// One average per minute, computed inside HealthKit. A wearable that
    /// writes heart rate every few seconds can put hundreds of thousands of
    /// raw samples into 30 days, which made this the slowest part of a sync;
    /// strain and resting HR already work on 1-minute bins.
    func heartRates(from: Date, to: Date) async throws -> [QuantitySample] {
        try await ensureAuthorized()
        let type = HKQuantityType(.heartRate)
        let unit = HKUnit.count().unitDivided(by: .minute())
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        let anchor = Calendar.current.startOfDay(for: from)
        return try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
                                                options: .discreteAverage, anchorDate: anchor,
                                                intervalComponents: DateComponents(minute: 1))
            q.initialResultsHandler = { _, collection, error in
                if let error { cont.resume(throwing: error); return }
                var out: [QuantitySample] = []
                collection?.enumerateStatistics(from: from, to: to) { stats, _ in
                    if let avg = stats.averageQuantity() {
                        out.append(QuantitySample(start: stats.startDate, end: stats.endDate,
                                                  value: avg.doubleValue(for: unit)))
                    }
                }
                cont.resume(returning: out)
            }
            store.execute(q)
        }
    }

    func hrvSDNN(from: Date, to: Date) async throws -> [QuantitySample] {
        try await quantitySamples(HKQuantityType(.heartRateVariabilitySDNN),
                                  unit: HKUnit.secondUnit(with: .milli), from: from, to: to)
    }

    /// True beat-to-beat RR intervals (ms) reconstructed from the heartbeat
    /// series (Apple Watch). Each series sample is expanded via
    /// `HKHeartbeatSeriesQuery`; consecutive beat timestamps give the RR
    /// interval, skipping any beat flagged `precededByGap`.
    func beatToBeatRR(from: Date, to: Date) async throws -> [QuantitySample] {
        try await ensureAuthorized()
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        let series: [HKHeartbeatSeriesSample] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: HKSeriesType.heartbeat(), predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: sort) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: samples as? [HKHeartbeatSeriesSample] ?? [])
            }
            store.execute(q)
        }

        var out: [QuantitySample] = []
        for sample in series {
            let beats = try await expand(series: sample)
            out.append(contentsOf: beats)
        }
        return out
    }

    /// Stream one heartbeat series into RR-interval samples.
    private func expand(series sample: HKHeartbeatSeriesSample) async throws -> [QuantitySample] {
        try await withCheckedThrowingContinuation { cont in
            var lastOffset: Double? = nil
            var rr: [QuantitySample] = []
            let q = HKHeartbeatSeriesQuery(heartbeatSeries: sample) { _, timeSinceStart, precededByGap, done, error in
                if let error { cont.resume(throwing: error); return }
                if !precededByGap, let last = lastOffset {
                    let intervalMs = (timeSinceStart - last) * 1000
                    if intervalMs > 250 && intervalMs < 2000 {   // physiologic 30–240 bpm
                        let beatTime = sample.startDate.addingTimeInterval(timeSinceStart)
                        rr.append(QuantitySample(date: beatTime, value: intervalMs))
                    }
                }
                lastOffset = timeSinceStart
                if done { cont.resume(returning: rr) }
            }
            store.execute(q)
        }
    }

    func restingHeartRate(from: Date, to: Date) async throws -> [QuantitySample] {
        try await quantitySamples(HKQuantityType(.restingHeartRate),
                                  unit: HKUnit.count().unitDivided(by: .minute()), from: from, to: to)
    }

    func respiratoryRate(from: Date, to: Date) async throws -> [QuantitySample] {
        try await quantitySamples(HKQuantityType(.respiratoryRate),
                                  unit: HKUnit.count().unitDivided(by: .minute()), from: from, to: to)
    }

    func oxygenSaturation(from: Date, to: Date) async throws -> [QuantitySample] {
        // HealthKit reports a 0–1 fraction; convert to percent.
        let pct = try await quantitySamples(HKQuantityType(.oxygenSaturation),
                                             unit: .percent(), from: from, to: to)
        return pct.map { QuantitySample(start: $0.start, end: $0.end, value: $0.value * 100) }
    }

    func wristTemperature(from: Date, to: Date) async throws -> [QuantitySample] {
        guard #available(iOS 16.0, *) else { return [] }
        return try await quantitySamples(HKQuantityType(.appleSleepingWristTemperature),
                                         unit: .degreeCelsius(), from: from, to: to)
    }

    func vo2Max(from: Date, to: Date) async throws -> [QuantitySample] {
        let unit = HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        return try await quantitySamples(HKQuantityType(.vo2Max), unit: unit, from: from, to: to)
    }

    // MARK: Sleep

    func sleepSegments(from: Date, to: Date) async throws -> [SleepSegment] {
        try await ensureAuthorized()
        let type = HKCategoryType(.sleepAnalysis)
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        return try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: sort) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                let segments = (samples as? [HKCategorySample] ?? []).compactMap { Self.mapSleep($0) }
                cont.resume(returning: segments)
            }
            store.execute(q)
        }
    }

    private static func mapSleep(_ s: HKCategorySample) -> SleepSegment? {
        guard let value = HKCategoryValueSleepAnalysis(rawValue: s.value) else { return nil }
        let stage: SleepStage
        switch value {
        case .inBed: stage = .inBed
        case .awake: stage = .awake
        case .asleepCore: stage = .core
        case .asleepDeep: stage = .deep
        case .asleepREM: stage = .rem
        case .asleepUnspecified: stage = .asleepUnspecified
        @unknown default: stage = .asleepUnspecified
        }
        return SleepSegment(start: s.startDate, end: s.endDate, stage: stage)
    }

    // MARK: Workouts

    func workouts(from: Date, to: Date) async throws -> [WorkoutSession] {
        try await ensureAuthorized()
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        let workouts: [HKWorkout] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: .workoutType(), predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: sort) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: samples as? [HKWorkout] ?? [])
            }
            store.execute(q)
        }

        var sessions: [WorkoutSession] = []
        for w in workouts {
            let hr = try await heartRates(from: w.startDate, to: w.endDate)
            let energy = w.statistics(for: HKQuantityType(.activeEnergyBurned))?
                .sumQuantity()?.doubleValue(for: .kilocalorie())
            sessions.append(WorkoutSession(start: w.startDate, end: w.endDate,
                                           activity: Self.mapActivity(w.workoutActivityType),
                                           heartRates: hr, activeEnergyKcal: energy))
        }
        return sessions
    }

    private static func mapActivity(_ type: HKWorkoutActivityType) -> WorkoutActivity {
        switch type {
        case .traditionalStrengthTraining, .functionalStrengthTraining: return .weightlifting
        case .highIntensityIntervalTraining, .crossTraining: return .hiit
        case .yoga, .pilates, .flexibility, .mindAndBody: return .yoga
        case .running: return .running
        case .cycling: return .cycling
        case .walking, .hiking: return .walking
        default: return .other
        }
    }
}
