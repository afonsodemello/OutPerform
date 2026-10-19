//
//  CombinedDataProvider.swift
//  OutPerform
//
//  "All sources": reads Apple Health, Google Health and the Bluetooth band
//  at the same time and blends them with `SourceMerger`, so each slice of
//  data comes from whichever source has it first and best.
//
//  • Apple Health and the band (both local) are read first, in parallel.
//    Google is then asked only for the days Apple Health has no data for,
//    and not at all when Apple covers the range, so syncs stay fast.
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
        var lastSkipped: Date?

        /// An error only counts if nothing succeeded after it.
        var isFailing: Bool {
            guard let e = lastErrorAt else { return false }
            return lastSuccess.map { $0 < e } ?? true
        }
    }

    private(set) var statuses: [SourceKind: Status] = [:]

    func notUsed(_ kind: SourceKind, _ reason: String?) { statuses[kind, default: Status()].notUsedReason = reason }
    func succeeded(_ kind: SourceKind) { statuses[kind, default: Status()].lastSuccess = Date() }
    /// Google wasn't needed: Apple Health already had that data.
    func skippedGoogle() { statuses[.google, default: Status()].lastSkipped = Date() }
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
            if !google.isAvailable() { return "Not available right now" }
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

    /// How a metric's data is bucketed when deciding whether Apple Health
    /// already has it.
    enum Bucketing {
        /// Calendar days; a day counts as covered with ≥ `minPerDay` samples.
        case days(minPerDay: Int)
        /// Nights (keyed by wake day); covered once the summed weight (asleep
        /// minutes, or beats) reaches `minWeight`.
        case nights(minWeight: Double)
    }

    /// Fetch one metric. Apple Health and the band are local and fast, so
    /// they're read first, in parallel. Google is then asked only for the
    /// days/nights Apple Health has nothing for (and not at all when Apple
    /// covers the whole range). Without Apple Health, Google covers everything.
    private func gather<T: Sendable>(from: Date, to: Date, bucketing: Bucketing,
                                     key: @escaping (T) -> Date,
                                     weight: @escaping (T) -> Double = { _ in 1 },
                                     coveredBy appleCoverage: Set<Date>? = nil,
                                     _ fetch: @escaping (HealthDataProvider, Date, Date) async throws -> [T]) async -> [SourceKind: [T]] {
        for k in SourceKind.allCases { board.notUsed(k, reason(k)) }
        let kinds = active
        let local = kinds.filter { $0 != .google }
        // Ask Apple Health for permission (if needed) before the timed calls,
        // so a permission sheet the user is reading can't count as a timeout.
        if local.contains(.appleHealth) { try? await apple.ensureAuthorized() }
        var results = await run(local, from: from, to: to, fetch)

        guard kinds.contains(.google) else { return results }
        var googleFrom = from, googleTo = to
        if kinds.contains(.appleHealth), let appleData = results[.appleHealth] {
            let covered = appleCoverage ?? Self.coveredKeys(appleData, bucketing: bucketing, key: key, weight: weight)
            let expected = SourceMerger.expectedKeys(from: from, to: to, now: Date(), nights: Self.isNights(bucketing))
            let missing = expected.subtracting(covered)
            guard let span = SourceMerger.fetchSpan(for: missing, nights: Self.isNights(bucketing), clampFrom: from, clampTo: to) else {
                board.skippedGoogle()
                return results
            }
            (googleFrom, googleTo) = span
        }
        let g = await run([.google], from: googleFrom, to: googleTo, fetch)
        results[.google] = g[.google]
        return results
    }

    private static func isNights(_ b: Bucketing) -> Bool { if case .nights = b { return true } else { return false } }

    private static func coveredKeys<T>(_ data: [T], bucketing: Bucketing, key: (T) -> Date, weight: (T) -> Double) -> Set<Date> {
        var totals: [Date: Double] = [:]
        for item in data { totals[key(item), default: 0] += weight(item) }
        let threshold: Double
        switch bucketing {
        case .days(let n): threshold = Double(n)
        case .nights(let w): threshold = w
        }
        return Set(totals.filter { $0.value >= threshold }.keys)
    }

    /// Run `fetch` against `kinds` in parallel, each under the time limit.
    /// Failures become empty results plus a status entry.
    private func run<T: Sendable>(_ kinds: [SourceKind], from: Date, to: Date,
                                  _ fetch: @escaping (HealthDataProvider, Date, Date) async throws -> [T]) async -> [SourceKind: [T]] {
        let calls = kinds.map { k in (k, provider(k)) }
        var results: [SourceKind: [T]] = [:]
        await withTaskGroup(of: (SourceKind, Result<[T], Error>).self) { group in
            for (kind, p) in calls {
                group.addTask {
                    do {
                        let value = try await Self.withTimeout(Self.perSourceTimeout) { try await fetch(p, from, to) }
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

    // Apple Health heart-rate coverage, shared by the metrics that are gated
    // on "was Apple recording that day" rather than on their own samples.
    private var appleHRCoverage: [String: Task<Set<Date>, Never>] = [:]

    private func appleHeartRateDays(from: Date, to: Date) async -> Set<Date>? {
        guard active.contains(.appleHealth) else { return nil }
        let k = "\(from.timeIntervalSince1970)-\(to.timeIntervalSince1970)"
        if let t = appleHRCoverage[k] { return await t.value }
        let apple = self.apple
        let t = Task { () -> Set<Date> in
            let hr = (try? await apple.heartRates(from: from, to: to)) ?? []
            return Self.coveredKeys(hr, bucketing: .days(minPerDay: 24),
                                    key: { Calendar.current.startOfDay(for: $0.start) }, weight: { _ in 1 })
        }
        appleHRCoverage = [k: t]   // keep only the current sync's window
        return await t.value
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

    private static func day(_ q: QuantitySample) -> Date { Calendar.current.startOfDay(for: q.start) }
    private static func night(_ q: QuantitySample) -> Date {
        Calendar.current.startOfDay(for: q.start.addingTimeInterval(6 * 3600))
    }

    func heartRates(from: Date, to: Date) async throws -> [QuantitySample] {
        // A day counts as covered once Apple has ≥ 24 readings (≈ 2 h of a
        // watch's 5-minute background sampling).
        SourceMerger.mergeSeries(await gather(from: from, to: to, bucketing: .days(minPerDay: 24), key: Self.day) {
            try await $0.heartRates(from: $1, to: $2)
        })
    }

    func beatToBeatRR(from: Date, to: Date) async throws -> [QuantitySample] {
        SourceMerger.mergeBeatsByNight(await gather(from: from, to: to, bucketing: .nights(minWeight: 200), key: Self.night) {
            try await $0.beatToBeatRR(from: $1, to: $2)
        })
    }

    func nightlyRMSSD(from: Date, to: Date) async throws -> [QuantitySample] {
        SourceMerger.mergeDaily(await gather(from: from, to: to, bucketing: .days(minPerDay: 1), key: Self.day) {
            try await $0.nightlyRMSSD(from: $1, to: $2)
        }, priority: SourceMerger.cardiacPriority)
    }

    func hrvSDNN(from: Date, to: Date) async throws -> [QuantitySample] {
        SourceMerger.mergeDaily(await gather(from: from, to: to, bucketing: .days(minPerDay: 1), key: Self.day) {
            try await $0.hrvSDNN(from: $1, to: $2)
        }, priority: SourceMerger.cardiacPriority)
    }

    func restingHeartRate(from: Date, to: Date) async throws -> [QuantitySample] {
        SourceMerger.mergeDaily(await gather(from: from, to: to, bucketing: .days(minPerDay: 1), key: Self.day) {
            try await $0.restingHeartRate(from: $1, to: $2)
        }, priority: SourceMerger.cardiacPriority)
    }

    func respiratoryRate(from: Date, to: Date) async throws -> [QuantitySample] {
        SourceMerger.mergeDaily(await gather(from: from, to: to, bucketing: .days(minPerDay: 1), key: Self.day) {
            try await $0.respiratoryRate(from: $1, to: $2)
        }, priority: SourceMerger.cardiacPriority)
    }

    func oxygenSaturation(from: Date, to: Date) async throws -> [QuantitySample] {
        SourceMerger.mergeDaily(await gather(from: from, to: to, bucketing: .days(minPerDay: 1), key: Self.day) {
            try await $0.oxygenSaturation(from: $1, to: $2)
        }, priority: SourceMerger.vitalsPriority)
    }

    func wristTemperature(from: Date, to: Date) async throws -> [QuantitySample] {
        SourceMerger.mergeDaily(await gather(from: from, to: to, bucketing: .days(minPerDay: 1), key: Self.day) {
            try await $0.wristTemperature(from: $1, to: $2)
        }, priority: SourceMerger.vitalsPriority)
    }

    func vo2Max(from: Date, to: Date) async throws -> [QuantitySample] {
        // VO2 max is written every few days, so gate it on whether Apple was
        // recording at all that day rather than on VO2 samples.
        let covered = await appleHeartRateDays(from: from, to: to)
        return SourceMerger.mergeDaily(await gather(from: from, to: to, bucketing: .days(minPerDay: 1), key: Self.day,
                                                    coveredBy: covered) {
            try await $0.vo2Max(from: $1, to: $2)
        }, priority: SourceMerger.vitalsPriority)
    }

    func sleepSegments(from: Date, to: Date) async throws -> [SleepSegment] {
        SourceMerger.mergeSleep(await gather(from: from, to: to, bucketing: .nights(minWeight: 60),
                                             key: { SourceMerger.nightKey($0, .current) },
                                             weight: { $0.stage.isAsleep ? $0.durationMinutes : 0 }) {
            try await $0.sleepSegments(from: $1, to: $2)
        })
    }

    func workouts(from: Date, to: Date) async throws -> [WorkoutSession] {
        // Rest days have no workouts, so gate on Apple's heart-rate coverage:
        // if Apple was recording that day, its workout list is complete.
        let covered = await appleHeartRateDays(from: from, to: to)
        return SourceMerger.mergeWorkouts(await gather(from: from, to: to, bucketing: .days(minPerDay: 1),
                                                       key: { Calendar.current.startOfDay(for: $0.start) },
                                                       coveredBy: covered) {
            try await $0.workouts(from: $1, to: $2)
        })
    }
}
