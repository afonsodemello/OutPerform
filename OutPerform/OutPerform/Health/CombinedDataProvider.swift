//
//  CombinedDataProvider.swift
//  OutPerform
//
//  "All sources": reads Apple Health, Google Health and the Bluetooth band
//  at the same time and blends them with `SourceMerger`, so each slice of
//  data comes from whichever source has it first and best.
//
//  • Every source is queried in parallel for every metric.
//  • Each call has its own time limit. A slow or failing source (say Google
//    is offline or its token expired) never holds up the sync; it's skipped
//    for that round and its status shows why.
//  • A source is used only when it's enabled in Settings and ready: Apple
//    Health available on the device, Google signed in, a band paired or
//    recordings on the phone.
//

import Foundation
import HealthKit
import Observation

/// Per-source health of the last combined sync, for the Settings screen.
@Observable
final class SourceStatusBoard {
    static let shared = SourceStatusBoard()

    struct Status: Equatable {
        /// Why the source is sitting out, if it is.
        var notUsedReason: String?
        var lastSuccess: Date?
        var lastError: String?
        var lastErrorAt: Date?

        /// An error only counts if nothing succeeded after it.
        var isFailing: Bool {
            guard let e = lastErrorAt else { return false }
            return lastSuccess.map { $0 < e } ?? true
        }
    }

    private(set) var statuses: [SourceKind: Status] = [:]

    func notUsed(_ kind: SourceKind, _ reason: String?) { statuses[kind, default: Status()].notUsedReason = reason }
    func succeeded(_ kind: SourceKind) { statuses[kind, default: Status()].lastSuccess = Date() }
    func failed(_ kind: SourceKind, _ message: String) {
        statuses[kind, default: Status()].lastError = message
        statuses[kind, default: Status()].lastErrorAt = Date()
    }
}

final class CombinedDataProvider: HealthDataProvider {
    let sourceType: DataSourceType = .combined

    private let apple = HealthKitProvider()
    private let google = GoogleHealthProvider()
    private let band = BandDataProvider()
    private let board = SourceStatusBoard.shared
    private let settings = AppSettings.shared

    /// Per-call time limit for one source. Generous for a 30-day first sync
    /// from Google; steady-state syncs fetch 2 days and finish in seconds.
    static let perSourceTimeout: TimeInterval = 45

    // MARK: Which sources take part

    private func reason(_ kind: SourceKind) -> String? {
        guard settings.combinedSources.contains(kind) else { return "Turned off" }
        switch kind {
        case .appleHealth:
            return apple.isAvailable() ? nil : "Not available on this device"
        case .google:
            if !google.isAvailable() { return "Google sign-in isn't set up in this build" }
            return GoogleAuthManager.shared.isSignedIn ? nil : "Not signed in"
        case .band:
            return BandManager.shared.isPaired ? nil : "No band paired"
        }
    }

    private var active: [SourceKind] { SourceKind.allCases.filter { reason($0) == nil } }

    private func provider(_ kind: SourceKind) -> HealthDataProvider {
        switch kind {
        case .appleHealth: return apple
        case .google:      return google
        case .band:        return band
        }
    }

    func isAvailable() -> Bool { true }

    /// Ask each enabled source for access. Google's interactive sign-in is
    /// started from Settings instead, so a sync never pops a browser.
    func requestAuthorization() async throws {
        var errors: [String] = []
        if settings.combinedSources.contains(.appleHealth), apple.isAvailable() {
            do { try await apple.requestAuthorization() } catch { errors.append("Apple Health: \(error.localizedDescription)") }
        }
        if settings.combinedSources.contains(.band) {
            try? await band.requestAuthorization()
        }
        if active.isEmpty {
            throw HealthDataError.network(errors.first ?? "Turn on at least one source in Settings → Data source.")
        }
    }

    // MARK: Fan-out

    /// Run `fetch` against every active source in parallel, each under the
    /// time limit. Failures become empty results plus a status entry.
    private func gather<T: Sendable>(_ fetch: @escaping (HealthDataProvider) async throws -> [T]) async -> [SourceKind: [T]] {
        let kinds = active
        for k in SourceKind.allCases { board.notUsed(k, reason(k)) }
        let calls = kinds.map { k in (k, provider(k)) }
        var results: [SourceKind: [T]] = [:]
        await withTaskGroup(of: (SourceKind, Result<[T], Error>).self) { group in
            for (kind, p) in calls {
                group.addTask {
                    do {
                        let value = try await Self.withTimeout(Self.perSourceTimeout) { try await fetch(p) }
                        return (kind, .success(value))
                    } catch {
                        return (kind, .failure(error))
                    }
                }
            }
            for await (kind, result) in group {
                switch result {
                case .success(let v):
                    results[kind] = v
                    board.succeeded(kind)
                case .failure(let e):
                    board.failed(kind, Self.describe(e))
                }
            }
        }
        return results
    }

    private static func describe(_ e: Error) -> String {
        if e is TimeoutError { return "Timed out — skipped this sync" }
        return e.localizedDescription
    }

    struct TimeoutError: Error {}

    nonisolated private static func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                                                             _ op: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimeoutError()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    // MARK: HealthDataProvider

    func heartRates(from: Date, to: Date) async throws -> [QuantitySample] {
        SourceMerger.mergeSeries(await gather { try await $0.heartRates(from: from, to: to) })
    }

    func beatToBeatRR(from: Date, to: Date) async throws -> [QuantitySample] {
        SourceMerger.mergeBeatsByNight(await gather { try await $0.beatToBeatRR(from: from, to: to) })
    }

    func nightlyRMSSD(from: Date, to: Date) async throws -> [QuantitySample] {
        SourceMerger.mergeDaily(await gather { try await $0.nightlyRMSSD(from: from, to: to) },
                                priority: SourceMerger.cardiacPriority)
    }

    func hrvSDNN(from: Date, to: Date) async throws -> [QuantitySample] {
        SourceMerger.mergeDaily(await gather { try await $0.hrvSDNN(from: from, to: to) },
                                priority: SourceMerger.cardiacPriority)
    }

    func restingHeartRate(from: Date, to: Date) async throws -> [QuantitySample] {
        SourceMerger.mergeDaily(await gather { try await $0.restingHeartRate(from: from, to: to) },
                                priority: SourceMerger.cardiacPriority)
    }

    func respiratoryRate(from: Date, to: Date) async throws -> [QuantitySample] {
        SourceMerger.mergeDaily(await gather { try await $0.respiratoryRate(from: from, to: to) },
                                priority: SourceMerger.cardiacPriority)
    }

    func oxygenSaturation(from: Date, to: Date) async throws -> [QuantitySample] {
        SourceMerger.mergeDaily(await gather { try await $0.oxygenSaturation(from: from, to: to) },
                                priority: SourceMerger.vitalsPriority)
    }

    func wristTemperature(from: Date, to: Date) async throws -> [QuantitySample] {
        SourceMerger.mergeDaily(await gather { try await $0.wristTemperature(from: from, to: to) },
                                priority: SourceMerger.vitalsPriority)
    }

    func vo2Max(from: Date, to: Date) async throws -> [QuantitySample] {
        SourceMerger.mergeDaily(await gather { try await $0.vo2Max(from: from, to: to) },
                                priority: SourceMerger.vitalsPriority)
    }

    func sleepSegments(from: Date, to: Date) async throws -> [SleepSegment] {
        SourceMerger.mergeSleep(await gather { try await $0.sleepSegments(from: from, to: to) })
    }

    func workouts(from: Date, to: Date) async throws -> [WorkoutSession] {
        SourceMerger.mergeWorkouts(await gather { try await $0.workouts(from: from, to: to) })
    }
}
