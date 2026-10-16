//
//  RecordedWorkoutsProvider.swift
//  OutPerform
//
//  Wraps whichever data source is active and adds the workouts you recorded
//  in the Exercise tab, so they count toward activity strain. A recorded
//  workout replaces any overlapping one the source reports (same workout,
//  seen twice), since yours carries the exact type and timing.
//

import Foundation

final class RecordedWorkoutsProvider: HealthDataProvider {
    let base: HealthDataProvider
    init(base: HealthDataProvider) { self.base = base }

    var sourceType: DataSourceType { base.sourceType }
    func isAvailable() -> Bool { base.isAvailable() }
    func requestAuthorization() async throws { try await base.requestAuthorization() }

    func workouts(from: Date, to: Date) async throws -> [WorkoutSession] {
        let recorded = ExerciseStore.shared.sessions(from: from, to: to).map(\.asWorkoutSession)
        let reported = try await base.workouts(from: from, to: to)
        let others = reported.filter { r in !recorded.contains { SourceMerger.sameWorkout($0, r) } }
        return (recorded + others).sorted { $0.start < $1.start }
    }

    func heartRates(from: Date, to: Date) async throws -> [QuantitySample] { try await base.heartRates(from: from, to: to) }
    func beatToBeatRR(from: Date, to: Date) async throws -> [QuantitySample] { try await base.beatToBeatRR(from: from, to: to) }
    func nightlyRMSSD(from: Date, to: Date) async throws -> [QuantitySample] { try await base.nightlyRMSSD(from: from, to: to) }
    func hrvSDNN(from: Date, to: Date) async throws -> [QuantitySample] { try await base.hrvSDNN(from: from, to: to) }
    func restingHeartRate(from: Date, to: Date) async throws -> [QuantitySample] { try await base.restingHeartRate(from: from, to: to) }
    func respiratoryRate(from: Date, to: Date) async throws -> [QuantitySample] { try await base.respiratoryRate(from: from, to: to) }
    func oxygenSaturation(from: Date, to: Date) async throws -> [QuantitySample] { try await base.oxygenSaturation(from: from, to: to) }
    func wristTemperature(from: Date, to: Date) async throws -> [QuantitySample] { try await base.wristTemperature(from: from, to: to) }
    func sleepSegments(from: Date, to: Date) async throws -> [SleepSegment] { try await base.sleepSegments(from: from, to: to) }
    func vo2Max(from: Date, to: Date) async throws -> [QuantitySample] { try await base.vo2Max(from: from, to: to) }
}
