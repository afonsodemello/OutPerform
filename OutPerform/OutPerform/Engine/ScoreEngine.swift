//
//  ScoreEngine.swift
//  OutPerform
//
//  Orchestrates the whole pipeline: pull raw biometrics from the active
//  provider, compute every metric per day in chronological order (so
//  baselines, sleep debt and ACWR carry forward correctly), and persist a
//  DailyRecord per day.
//
//  Two-phase sync (foreground):
//    1. fetchRaw()    — network only, no UI freeze, stores a PendingSync
//    2. applyPending() — compute + persist, triggered by user from the banner
//
//  Single-phase sync (background tasks / explicit manual refresh):
//    refresh() — calls both phases in sequence, as before.
//

import Foundation
import SwiftData

@MainActor
@Observable
final class ScoreEngine {
    private(set) var provider: HealthDataProvider
    private let settings: AppSettings
    private let config = AlgorithmConfig.shared

    /// Nights of baseline data required before baseline-dependent scores unlock.
    static let calibrationNights = 14
    private let modelContext: ModelContext

    var isRefreshing = false
    var lastRefresh: Date?
    var lastError: String?
    /// Timestamp of the most recent refresh START — set even when the refresh
    /// fails, so callers can rate-limit retries when auth is broken.
    var lastRefreshAttempt: Date?

    /// True while the network-only fetch phase is in flight.
    var isFetchingRaw = false
    /// True when raw data has been fetched but computations haven't been applied yet.
    var hasPendingData = false
    private var pendingSync: PendingSync?

    /// End timestamp of the last successful sync (used by WidgetBridge / BGTask scheduling).
    private static let lastSyncKey = "ScoreEngine.lastSyncEnd"
    static var lastSyncEnd: Date? {
        get { UserDefaults(suiteName: WidgetBridge.suiteName)?.object(forKey: lastSyncKey) as? Date }
        set { UserDefaults(suiteName: WidgetBridge.suiteName)?.set(newValue, forKey: lastSyncKey) }
    }

    /// The earliest day that still needs a HealthKit fetch, computed after each
    /// successful apply. Lets the next sync skip days that are already complete
    /// so steady-state syncs only pull the last 2 days instead of 30.
    /// Cleared on reset so the next sync does a full backfill.
    private static let nextFetchStartKey = "ScoreEngine.nextFetchStart"
    static var nextFetchStart: Date? {
        get { UserDefaults(suiteName: WidgetBridge.suiteName)?.object(forKey: nextFetchStartKey) as? Date }
        set { UserDefaults(suiteName: WidgetBridge.suiteName)?.set(newValue, forKey: nextFetchStartKey) }
    }

    /// Days (start-of-day epoch seconds) for which we fetched heart-rate but found
    /// none — the device simply wasn't worn. Tracked so gap-filling doesn't keep
    /// re-fetching genuinely empty days forever, while still backfilling days that
    /// DO have data but were skipped by the incremental window. Cleared on reset.
    private static let emptyDaysKey = "ScoreEngine.knownEmptyDays"
    static var knownEmptyDays: Set<Double> {
        get { Set((UserDefaults(suiteName: WidgetBridge.suiteName)?.array(forKey: emptyDaysKey) as? [Double]) ?? []) }
        set { UserDefaults(suiteName: WidgetBridge.suiteName)?.set(Array(newValue), forKey: emptyDaysKey) }
    }

    /// The single in-flight refresh. Owned here (unstructured Task) so a scroll
    /// gesture / view update can never cancel a sync mid-way.
    private var refreshTask: Task<Void, Never>?

    init(provider: HealthDataProvider, settings: AppSettings, modelContext: ModelContext) {
        self.provider = provider
        self.settings = settings
        self.modelContext = modelContext
    }

    func setProvider(_ p: HealthDataProvider) { provider = p }

    /// Read-only access for UI-side summaries (illness watch).
    var modelContextForReads: ModelContext { modelContext }

    // MARK: Date windows

    nonisolated private static func sleepWindow(for day: Date, now: Date) -> (Date, Date) {
        let cal = Calendar.current
        let sod = cal.startOfDay(for: day)
        let start = cal.date(byAdding: .hour, value: -6, to: sod)!   // prev 18:00
        let end = min(now, cal.date(byAdding: .hour, value: 14, to: sod)!)
        return (start, end)
    }

    nonisolated private static func dayWindow(for day: Date, now: Date) -> (Date, Date) {
        let cal = Calendar.current
        let sod = cal.startOfDay(for: day)
        return (sod, min(now, cal.date(byAdding: .day, value: 1, to: sod)!))
    }

    // MARK: Refresh

    /// Trigger a full fetch+compute refresh. Used by background tasks and explicit
    /// manual refresh actions (pull-to-refresh, Settings sync button). Concurrent
    /// callers JOIN the same task rather than spawning duplicates.
    func refresh(daysBack: Int = 30) async {
        if let existing = refreshTask {
            await existing.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(daysBack: daysBack)
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    /// Phase 1 of the two-phase foreground flow: fetch raw biometrics from the
    /// provider. Does NOT compute or modify stored records. After this returns,
    /// `hasPendingData` is true and the banner should offer the user an Apply action.
    func fetchRaw(daysBack: Int = 30) async {
        guard !isFetchingRaw, !isRefreshing else { return }
        isFetchingRaw = true
        lastError = nil
        lastRefreshAttempt = Date()
        defer { isFetchingRaw = false }
        do {
            pendingSync = try await fetchRawInternal(daysBack: daysBack)
            hasPendingData = true
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Phase 2 of the two-phase foreground flow: compute scores from the staged
    /// raw data and persist results. Call when the user taps "Apply" in the banner.
    func applyPending() async {
        guard let pending = pendingSync else { return }
        isRefreshing = true
        pendingSync = nil
        hasPendingData = false
        defer { isRefreshing = false }
        do {
            try await applyInternal(pending)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Internal two-phase implementation

    private func performRefresh(daysBack: Int) async {
        isRefreshing = true
        lastError = nil
        lastRefreshAttempt = Date()
        defer { isRefreshing = false }
        do {
            let pending = try await fetchRawInternal(daysBack: daysBack)
            try await applyInternal(pending)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Runs the network fetch phase. All I/O happens here; no store writes.
    ///
    /// Ordering is critical for UI responsiveness:
    ///  1. Compute the fetch window from UserDefaults only (no SwiftData).
    ///  2. Dispatch all 10 provider calls via `async let` — they run on the
    ///     cooperative thread pool immediately, before ANY blocking work.
    ///  3. While network I/O is in flight, do the ONE SwiftData read and
    ///     extract to Sendable value types. This brief block (~10–50 ms) is
    ///     overlapped with seconds of network wait, so the user never feels it.
    ///  4. Await the I/O results (just struct construction at this point).
    ///
    /// Heavy work (hrMax, calibratedOverall, priors dict, computeAll) stays
    /// entirely in the detached Task inside applyInternal.
    private func fetchRawInternal(daysBack: Int) async throws -> PendingSync {
        let now = Date()
        let cal = Calendar.current
        let rangeStart = cal.date(byAdding: .day, value: -daysBack, to: cal.startOfDay(for: now))!

        // ── Step 1: Compute the smart fetch window ────────────────────────────
        // Start from the oldest day that still needs data (persisted after each
        // successful apply), but never more than 2 days ago in steady state.
        // Falls back to full rangeStart on first sync or after a reset.
        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: cal.startOfDay(for: now))!
        let fetchWindowStart: Date = {
            guard let next = Self.nextFetchStart else { return rangeStart } // first sync
            // Clamp: never older than rangeStart, never newer than 2 days ago
            return max(rangeStart, min(next, twoDaysAgo))
        }()
        let dataFetchStart = cal.date(byAdding: .hour, value: -6, to: fetchWindowStart)!

        // ── Step 2: Launch all provider calls BEFORE any SwiftData access ────
        // async-let child tasks run on the cooperative thread pool — the main
        // actor is NOT blocked by these while they are in flight.
        async let hr       = provider.heartRates(from: dataFetchStart, to: now)
        async let beatRR   = provider.beatToBeatRR(from: dataFetchStart, to: now)
        async let nightRMSSD = provider.nightlyRMSSD(from: dataFetchStart, to: now)
        async let hrv      = provider.hrvSDNN(from: dataFetchStart, to: now)
        async let rhr      = provider.restingHeartRate(from: dataFetchStart, to: now)
        async let resp     = provider.respiratoryRate(from: dataFetchStart, to: now)
        async let spo2     = provider.oxygenSaturation(from: dataFetchStart, to: now)
        async let temp     = provider.wristTemperature(from: dataFetchStart, to: now)
        async let sleep    = provider.sleepSegments(from: dataFetchStart, to: now)
        async let workouts = provider.workouts(from: dataFetchStart, to: now)
        async let vo2      = provider.vo2Max(from: dataFetchStart, to: now)

        // ── Step 3: SwiftData read while network I/O is in flight ────────────
        // ONE fetch (was two). Blocks the main actor for ~10–50 ms but is
        // fully overlapped with the seconds-long network wait above.
        let allStored   = (try? modelContext.fetch(FetchDescriptor<DailyRecord>())) ?? []
        let storedValues = allStored.map { DayValues(from: $0) }   // Sendable snapshot

        // Snapshot settings/config scalars so the detached task never needs
        // to touch AppSettings or AlgorithmConfig (both main-actor singletons).
        let age                  = settings.age
        let hrMaxMethodRawValue  = config.hrMaxMethod.rawValue
        let strainScale          = config.strainScale
        let strainCoefficient    = config.strainCoefficient
        let defaultSleepNeedMin  = config.defaultSleepNeedMin
        let recoveryWeights      = config.recoveryWeights
        let sleepWeights         = config.sleepWeights
        let wakeMinuteOfDay      = settings.wakeMinuteOfDay
        let focusCalibrationOffset = settings.focusCalibrationOffset
        let scoringModel         = config.scoringModel

        // ── Step 4: Collect I/O results (trivial at this point) ──────────────
        let raw = RawData(
            hr:       try await hr,
            beatRR:   try await beatRR,
            hrv:      try await hrv,
            rhr:      try await rhr,
            resp:     try await resp,
            spo2:     try await spo2,
            temp:     try await temp,
            nightlyRMSSD: try await nightRMSSD,
            sleep:    try await sleep,
            workouts: try await workouts,
            vo2:      try await vo2)

        return PendingSync(
            raw: raw,
            storedValues: storedValues,
            age: age,
            hrMaxMethodRawValue: hrMaxMethodRawValue,
            strainScale: strainScale,
            strainCoefficient: strainCoefficient,
            defaultSleepNeedMin: defaultSleepNeedMin,
            recoveryWeights: recoveryWeights,
            sleepWeights: sleepWeights,
            wakeMinuteOfDay: wakeMinuteOfDay,
            focusCalibrationOffset: focusCalibrationOffset,
            scoringModel: scoringModel,
            daysBack: daysBack,
            now: now,
            fetchedDayStart: fetchWindowStart)
    }

    /// Runs the compute + persist phase on a staged `PendingSync`.
    private func applyInternal(_ pending: PendingSync) async throws {
        // ALL heavy work is in this detached task — no computation runs on the main
        // actor. This includes hrMax (O(n) over potentially thousands of HR samples),
        // building the priors dict, the calibration gate, and the full day-by-day pass.
        let computed: [DayValues] = await Task.detached(priority: .utility) {
            let cal = Calendar.current

            // hrMax: previously computed on main actor — moved here so raw.hr.map(\.value)
            // (potentially 10 k+ elements) never blocks the UI thread.
            let hrMax: Double
            if pending.scoringModel == .openScience {
                // Tanaka, or the observed 99.5th percentile when higher.
                hrMax = EffortScorer.hrMax(age: pending.age, observed: pending.raw.hr.map(\.value))
            } else {
                hrMax = StrainCalculator.personalisedHRMax(
                    age: pending.age,
                    allHeartRates: pending.raw.hr.map(\.value),
                    method: StrainCalculator.HRMaxMethod(rawValue: pending.hrMaxMethodRawValue) ?? .max)
            }

            // Calibration gate — previously done on main actor after second SwiftData fetch.
            let storedNightsHRV = pending.storedValues.filter { $0.hrv != nil }.count
            let storedNightsRHR = pending.storedValues.filter { $0.restingHR != nil }.count
            let calibratedOverall = Swift.min(storedNightsHRV, storedNightsRHR) >= ScoreEngine.calibrationNights

            // Priors dict — previously built on main actor; now built from the
            // already-extracted [DayValues] which are fully Sendable.
            var priors: [Date: DayValues] = [:]
            priors.reserveCapacity(pending.storedValues.count)
            for dv in pending.storedValues {
                priors[cal.startOfDay(for: dv.date)] = dv
            }

            let ctx = ComputeContext(
                hrMax: hrMax,
                strainScale: pending.strainScale,
                strainCoefficient: pending.strainCoefficient,
                defaultSleepNeedMin: pending.defaultSleepNeedMin,
                recoveryWeights: pending.recoveryWeights,
                sleepWeights: pending.sleepWeights,
                wakeMinuteOfDay: pending.wakeMinuteOfDay,
                focusCalibrationOffset: pending.focusCalibrationOffset,
                scoringModel: pending.scoringModel)

            return Self.computeAll(daysBack: pending.daysBack, now: pending.now, raw: pending.raw,
                                   priors: priors, calibratedOverall: calibratedOverall, ctx: ctx)
        }.value

        // APPLY in one go on the main actor.
        // ONE bulk fetch to build the existing-record map — replaces the 31
        // individual per-day queries that upsertRecord used to fire in a loop.
        let allExisting = (try? modelContext.fetch(FetchDescriptor<DailyRecord>())) ?? []
        var existingByDate = Dictionary(
            uniqueKeysWithValues: allExisting.map {
                (Calendar.current.startOfDay(for: $0.date), $0)
            })
        for dv in computed {
            let sod = Calendar.current.startOfDay(for: dv.date)
            let record: DailyRecord
            if let existing = existingByDate[sod] {
                record = existing
            } else {
                let new = DailyRecord(date: sod)
                modelContext.insert(new)
                existingByDate[sod] = new
                record = new
            }
            dv.apply(to: record)
        }
        try modelContext.save()
        lastRefresh = pending.now
        Self.lastSyncEnd = pending.now

        // Update knownEmptyDays and compute nextFetchStart.
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let rangeStart = cal.date(byAdding: .day, value: -pending.daysBack, to: today)!
        var empty = Self.knownEmptyDays
        for record in computed {
            let day = cal.startOfDay(for: record.date)
            let daysOld = cal.dateComponents([.day], from: day, to: today).day ?? 0
            if day >= pending.fetchedDayStart, daysOld >= 3, record.dayStrain == nil {
                empty.insert(day.timeIntervalSince1970)
            } else if record.dayStrain != nil {
                empty.remove(day.timeIntervalSince1970)
            }
        }
        Self.knownEmptyDays = empty

        // Find the oldest day in the window that still lacks any usable data and
        // isn't confirmed empty — that's where the next sync needs to start fetching.
        // A day is "done" if it has any health metric OR is in knownEmptyDays (stable empty).
        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: today)!
        let oldestIncomplete = computed
            .filter { dv in
                let day = cal.startOfDay(for: dv.date)
                guard day < twoDaysAgo else { return false } // recent days always re-fetch
                let hasData = dv.hrv != nil || dv.restingHR != nil
                    || dv.dayStrain != nil || dv.totalSleepMin != nil
                let isKnownEmpty = empty.contains(day.timeIntervalSince1970)
                return !hasData && !isKnownEmpty
            }
            .map { cal.startOfDay(for: $0.date) }
            .min()
        // Next fetch starts from the oldest incomplete day, clamped to rangeStart.
        // If everything in the window is done, only re-fetch the last 2 days.
        Self.nextFetchStart = oldestIncomplete.map { max($0, rangeStart) } ?? twoDaysAgo
    }

    // MARK: - Private value types

    private struct RawData: Sendable {
        var hr, beatRR, hrv, rhr, resp, spo2, temp: [QuantitySample]
        var nightlyRMSSD: [QuantitySample]
        var sleep: [SleepSegment]
        var workouts: [WorkoutSession]
        var vo2: [QuantitySample]
    }

    /// All inputs needed by `applyInternal`, captured at fetch time so the compute
    /// pass is deterministic regardless of when the user taps "Apply".
    ///
    /// Heavy work (hrMax, priors dict, calibratedOverall) is deliberately NOT done
    /// here — it runs inside the detached Task in applyInternal so the main actor
    /// is never blocked by computation during the fetch phase.
    private struct PendingSync: Sendable {
        let raw: RawData
        /// Value-type snapshot of the SwiftData store at fetch time.
        /// Used in the detached task to build the priors dict and calibration counts
        /// without touching SwiftData again.
        let storedValues: [DayValues]
        // Formula parameter snapshots (all Sendable scalars from main-actor singletons).
        let age: Int
        let hrMaxMethodRawValue: String
        let strainScale: Double
        let strainCoefficient: Double
        let defaultSleepNeedMin: Double
        let recoveryWeights: RecoveryCalculator.Weights
        let sleepWeights: SleepCalculator.Weights
        let wakeMinuteOfDay: Int
        let focusCalibrationOffset: Double
        let scoringModel: ScoringModel
        let daysBack: Int
        let now: Date
        let fetchedDayStart: Date
    }

    /// Immutable snapshot of every formula parameter the compute pass needs.
    /// Captured on the main actor BEFORE dispatching, so the background loop never
    /// touches the live (main-actor) `AlgorithmConfig` / `AppSettings` singletons.
    private struct ComputeContext: Sendable {
        var hrMax: Double
        var strainScale: Double
        var strainCoefficient: Double
        var defaultSleepNeedMin: Double
        var recoveryWeights: RecoveryCalculator.Weights
        var sleepWeights: SleepCalculator.Weights
        var wakeMinuteOfDay: Int
        var focusCalibrationOffset: Double
        var scoringModel: ScoringModel
        var openScience: Bool { scoringModel == .openScience }
    }

    /// Plain value-type mirror of a `DailyRecord`'s computed fields. The whole
    /// chronological pass runs on these OFF the main actor; results are then copied
    /// back into the SwiftData models in one pass on the main actor. `feltGood` is
    /// deliberately absent — it's a user check-in the engine must never overwrite.
    private struct DayValues: Sendable, FocusDaySource {
        var date: Date

        var rmssd, sdnn, hrv, dfaAlpha1: Double?
        var restingHR, respiratoryRate, spo2Avg, spo2Min, skinTempC: Double?

        var totalSleepMin, timeInBedMin, remMin, deepMin, coreMin, awakeMin: Double?
        var sleepEfficiency, restorativePct: Double?
        var wakeEvents: Int?
        var sleepOnset, sleepWake: Date?

        var dayStrain, activityStrain, dayTRIMP, acwr, monotony: Double?

        var recovery, sleepPerformance, stress, readiness, vo2Max: Double?
        var sleepNeedMin, sleepDebtMin, odi, cognitiveReadiness: Double?

        init(date: Date) { self.date = date }

        /// Seed from an existing persisted record (preserves values a refresh
        /// shouldn't blank out when the new fetch has no data for that field).
        init(from r: DailyRecord) {
            date = r.date
            rmssd = r.rmssd; sdnn = r.sdnn; hrv = r.hrv; dfaAlpha1 = r.dfaAlpha1
            restingHR = r.restingHR; respiratoryRate = r.respiratoryRate
            spo2Avg = r.spo2Avg; spo2Min = r.spo2Min; skinTempC = r.skinTempC
            totalSleepMin = r.totalSleepMin; timeInBedMin = r.timeInBedMin
            remMin = r.remMin; deepMin = r.deepMin; coreMin = r.coreMin; awakeMin = r.awakeMin
            sleepEfficiency = r.sleepEfficiency; restorativePct = r.restorativePct
            wakeEvents = r.wakeEvents; sleepOnset = r.sleepOnset; sleepWake = r.sleepWake
            dayStrain = r.dayStrain; activityStrain = r.activityStrain; dayTRIMP = r.dayTRIMP
            acwr = r.acwr; monotony = r.monotony
            recovery = r.recovery; sleepPerformance = r.sleepPerformance
            stress = r.stress; readiness = r.readiness; vo2Max = r.vo2Max
            sleepNeedMin = r.sleepNeedMin; sleepDebtMin = r.sleepDebtMin
            odi = r.odi; cognitiveReadiness = r.cognitiveReadiness
        }

        /// Copy the computed fields back into a persisted record (main actor).
        func apply(to r: DailyRecord) {
            r.rmssd = rmssd; r.sdnn = sdnn; r.hrv = hrv; r.dfaAlpha1 = dfaAlpha1
            r.restingHR = restingHR; r.respiratoryRate = respiratoryRate
            r.spo2Avg = spo2Avg; r.spo2Min = spo2Min; r.skinTempC = skinTempC
            r.totalSleepMin = totalSleepMin; r.timeInBedMin = timeInBedMin
            r.remMin = remMin; r.deepMin = deepMin; r.coreMin = coreMin; r.awakeMin = awakeMin
            r.sleepEfficiency = sleepEfficiency; r.restorativePct = restorativePct
            r.wakeEvents = wakeEvents; r.sleepOnset = sleepOnset; r.sleepWake = sleepWake
            r.dayStrain = dayStrain; r.activityStrain = activityStrain; r.dayTRIMP = dayTRIMP
            r.acwr = acwr; r.monotony = monotony
            r.recovery = recovery; r.sleepPerformance = sleepPerformance
            r.stress = stress; r.readiness = readiness; r.vo2Max = vo2Max
            r.sleepNeedMin = sleepNeedMin; r.sleepDebtMin = sleepDebtMin
            r.odi = odi; r.cognitiveReadiness = cognitiveReadiness
        }
    }

    // MARK: Per-day computation (off the main actor)

    /// Run the full chronological pass on background-safe value types and return a
    /// finished `DayValues` per day. Pure: no SwiftData, no main-actor state — every
    /// input is a `Sendable` snapshot, so this is safe to call from a detached task.
    nonisolated private static func computeAll(
        daysBack: Int, now: Date, raw: RawData,
        priors: [Date: DayValues], calibratedOverall: Bool, ctx: ComputeContext) -> [DayValues] {
        let cal = Calendar.current
        var history: [DayValues] = []
        history.reserveCapacity(daysBack + 1)
        var carriedDebt = 0.0
        var acwrState: StrainCalculator.ACWRState?

        for offset in stride(from: daysBack, through: 0, by: -1) {
            // Exit early if the parent task was cancelled (e.g. BGTask expiration).
            if Task.isCancelled { break }
            let day = cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: now))!
            let prior = priors[cal.startOfDay(for: day)]
            let record = computeDay(day: day, now: now, raw: raw, prior: prior,
                                    history: history, carriedDebt: &carriedDebt,
                                    acwrState: &acwrState,
                                    calibratedOverall: calibratedOverall, ctx: ctx)
            history.append(record)
        }
        return history
    }

    nonisolated private static func computeDay(
                            day: Date, now: Date, raw: RawData, prior: DayValues?,
                            history: [DayValues],
                            carriedDebt: inout Double,
                            acwrState: inout StrainCalculator.ACWRState?,
                            calibratedOverall: Bool, ctx: ComputeContext) -> DayValues {
        let hrMax = ctx.hrMax
        // Seed from the prior persisted values so fields without new data this
        // refresh are carried forward unchanged (non-destructive semantics).
        var record = prior ?? DayValues(date: Calendar.current.startOfDay(for: day))
        let (sStart, sEnd) = sleepWindow(for: day, now: now)
        let (dStart, dEnd) = dayWindow(for: day, now: now)

        // NON-DESTRUCTIVE: a refresh must never blank out data already shown.
        // We only overwrite a field when the new fetch actually has a value for
        // it; a transient empty/slow fetch leaves the existing value in place.

        // --- Sleep ---
        let sleepSegs = raw.sleep.filter { $0.start < sEnd && $0.end > sStart }
        let sm = SleepCalculator.metrics(from: sleepSegs)
        if sm.totalSleepMin > 0 {        // only update when this night has data
            record.totalSleepMin = sm.totalSleepMin
            record.timeInBedMin = sm.timeInBedMin
            record.remMin = sm.remMin
            record.deepMin = sm.deepMin
            record.coreMin = sm.coreMin
            record.awakeMin = sm.awakeMin
            record.sleepEfficiency = sm.efficiencyPct
            record.restorativePct = sm.restorativePct
            record.wakeEvents = sm.wakeEvents
            record.sleepOnset = sm.onset
            record.sleepWake = sm.wake
        }

        // --- Sleep-window biometrics ---
        let sleepHR = raw.hr.filter { $0.start >= sStart && $0.start <= sEnd }

        let seriesRR = raw.beatRR.filter { $0.start >= sStart && $0.start <= sEnd }
                                 .sorted { $0.start < $1.start }.map(\.value)
        if seriesRR.count >= 20 {
            record.rmssd = HRVAnalysis.rmssd(rrIntervalsMs: seriesRR)
            record.dfaAlpha1 = HRVAnalysis.dfaAlpha1(rrIntervalsMs: seriesRR)
        }
        // Provider-supplied daily summaries (HRV, RHR, skin temp) are calendar-day
        // aggregates timestamped anywhere from midnight to end-of-day. Widening to
        // sStart..dEnd (prev 18:00 → current midnight) ensures we don't drop a
        // summary that lands after the 14:00 sleep-window cutoff.
        // A source that analysed the night's beats itself (Bluetooth band)
        // supplies a windowed RMSSD; prefer it over the whole-window value.
        if let nightly = lastValue(raw.nightlyRMSSD, sStart, dEnd) { record.rmssd = nightly }
        if let providedHRV = mean(raw.hrv, sStart, dEnd) { record.sdnn = providedHRV }
        record.hrv = record.rmssd ?? record.sdnn ?? record.hrv

        // Resting HR: provider value, else 5th-percentile of sleep HR.
        if let providerRHR = lastValue(raw.rhr, sStart, dEnd) {
            record.restingHR = providerRHR
        } else if !sleepHR.isEmpty {
            record.restingHR = Stats.percentile(sleepHR.map(\.value), 0.05)
        }

        if let resp = mean(raw.resp, sStart, sEnd) { record.respiratoryRate = resp }
        let spo2Window = raw.spo2.filter { $0.start >= sStart && $0.start <= sEnd }
        if !spo2Window.isEmpty {
            record.spo2Avg = Stats.mean(spo2Window.map(\.value))
            record.spo2Min = spo2Window.map(\.value).min()
            if sm.totalSleepMin > 0,
               let apnea = SleepApneaScreener.screen(spo2: spo2Window, sleepHours: sm.totalSleepMin / 60) {
                record.odi = apnea.odi
            }
        }
        if let temp = mean(raw.temp, sStart, dEnd) { record.skinTempC = temp }

        // --- Strain (only recompute when we actually have heart-rate today) ---
        let dayHR = raw.hr.filter { $0.start >= dStart && $0.start <= dEnd }
        // Resting HR for %HRR: tonight's sleeping floor, else the day's 10th pct.
        let effortRHR = record.restingHR ?? (dayHR.isEmpty ? nil : Stats.percentile(dayHR.map(\.value), 0.10))
        if ctx.openScience {
            if let rhr = effortRHR, let t = EffortScorer.trimp(dayHR, restingHR: rhr, hrMax: hrMax) {
                record.dayTRIMP = t
                record.dayStrain = EffortScorer.strain21(trimp: t)
            }
        } else if !dayHR.isEmpty {
            let dayTRIMP = StrainCalculator.trimp(heartRates: dayHR, hrMax: hrMax)
            record.dayTRIMP = dayTRIMP
            record.dayStrain = StrainCalculator.strain(fromTRIMP: dayTRIMP,
                                                       scale: ctx.strainScale,
                                                       coefficient: ctx.strainCoefficient)
        }

        let dayWorkouts = raw.workouts.filter { $0.start >= dStart && $0.start <= dEnd }
        var activityTRIMP = 0.0
        for w in dayWorkouts {
            let workoutHR = w.heartRates.isEmpty
                ? raw.hr.filter { $0.start >= w.start && $0.start <= w.end }
                : w.heartRates
            if ctx.openScience {
                if let rhr = effortRHR {
                    activityTRIMP += EffortScorer.trimp(workoutHR, restingHR: rhr, hrMax: hrMax) ?? 0
                }
            } else {
                let t = StrainCalculator.trimp(heartRates: workoutHR, hrMax: hrMax)
                activityTRIMP += StrainCalculator.adjustedTRIMP(t, activity: w.activity)
            }
        }
        if activityTRIMP > 0 {
            record.activityStrain = ctx.openScience
                ? EffortScorer.strain21(trimp: activityTRIMP)
                : StrainCalculator.strain(fromTRIMP: activityTRIMP,
                                          scale: ctx.strainScale, coefficient: ctx.strainCoefficient)
        }

        // --- VO2 max ---
        if let v = lastValue(raw.vo2, dStart, dEnd) {
            record.vo2Max = v
        } else if let rhrVal = record.restingHR {
            record.vo2Max = VO2MaxCalculator.estimate(hrMax: hrMax, restingHR: rhrVal)
        }

        // --- Sleep need (uses yesterday's strain + carried debt) ---
        let yesterdayStrain = history.last?.dayStrain ?? 0
        let recent = (history.suffix(30) + [record])
        let realNights = recent.compactMap(\.totalSleepMin).filter { $0 >= 180 }
        let lowStrainSleep = recent
            .filter { ($0.dayStrain ?? 99) < 8 }
            .compactMap(\.totalSleepMin)
            .filter { $0 >= 180 }
        let baseline: Double
        if lowStrainSleep.count >= 3 {
            baseline = SleepNeedCalculator.baseline(lowStrainSleepMinutes: lowStrainSleep)
        } else if !realNights.isEmpty {
            baseline = SleepNeedCalculator.baseline(lowStrainSleepMinutes: realNights)
        } else {
            baseline = ctx.defaultSleepNeedMin
        }
        let napMinutes = 0.0
        let pastNightNeedMin: Double
        if ctx.openScience {
            // Need = personal base + carried debt; 55% of the shortfall carries on.
            pastNightNeedMin = baseline + carriedDebt
            if sm.totalSleepMin > 0 {
                carriedDebt = SleepDebtModel.nextDebt(baseNeedMin: baseline, currentDebtMin: carriedDebt,
                                                      sleptMin: sm.totalSleepMin)
            }
            record.sleepDebtMin = carriedDebt
            record.sleepNeedMin = baseline + carriedDebt
        } else {
            let pastNightNeed = SleepNeedCalculator.sleepNeed(baselineMinutes: baseline,
                                                              yesterdayStrain: yesterdayStrain,
                                                              carriedDebt: carriedDebt,
                                                              napMinutes: napMinutes)
            pastNightNeedMin = pastNightNeed.needMinutes
            if sm.totalSleepMin > 0 {
                carriedDebt = SleepNeedCalculator.updatedDebt(previousDebt: carriedDebt,
                                                              previousNeed: pastNightNeed.needMinutes,
                                                              previousActual: sm.totalSleepMin)
            }
            record.sleepDebtMin = carriedDebt
            let tonightNeed = SleepNeedCalculator.sleepNeed(baselineMinutes: baseline,
                                                            yesterdayStrain: record.dayStrain ?? 0,
                                                            carriedDebt: carriedDebt,
                                                            napMinutes: napMinutes)
            record.sleepNeedMin = tonightNeed.needMinutes
        }

        // --- Sleep performance ---
        let bedtimes = (history.suffix(7) + [record]).compactMap { $0.sleepOnset }.map { onset -> Double in
            let c = Calendar.current
            let h = Double(c.component(.hour, from: onset)) + Double(c.component(.minute, from: onset)) / 60
            return h < 12 ? h + 24 : h
        }
        let bedtimeStd = Stats.stdDev(bedtimes)
        if sm.totalSleepMin > 0 {
            if ctx.openScience {
                record.sleepPerformance = RestScorer.score(metrics: sm, needMin: pastNightNeedMin,
                                                           bedtimeStdHours: bedtimeStd)
            } else {
                let perf = SleepCalculator.performance(metrics: sm, sleepNeedMin: pastNightNeedMin,
                                                       bedtimeStdHours: bedtimeStd, weights: ctx.sleepWeights)
                record.sleepPerformance = perf.score
            }
        }

        // --- Recovery (needs baselines from prior nights) ---
        let recInput = RecoveryInput(
            rmssd: record.hrv, restingHR: record.restingHR,
            respiratoryRate: record.respiratoryRate, sleepPerformance: record.sleepPerformance,
            skinTempC: record.skinTempC, spo2Avg: record.spo2Avg,
            rmssdMean3: rollingMean(history, \.hrv, 3),
            rmssdStd7: rollingStd(history, \.hrv, 7),
            rhrMean7: rollingMean(history, \.restingHR, 7),
            rhrStd14: rollingStd(history, \.restingHR, 14),
            respMean14: rollingMean(history, \.respiratoryRate, 14),
            respStd14: rollingStd(history, \.respiratoryRate, 14),
            skinTempMean14: rollingMean(history, \.skinTempC, 14))
        let nightsHRV = history.compactMap(\.hrv).count + (record.hrv != nil ? 1 : 0)
        let nightsRHR = history.compactMap(\.restingHR).count + (record.restingHR != nil ? 1 : 0)
        let baselineReady = calibratedOverall
            || Swift.min(nightsHRV, nightsRHR) >= Self.calibrationNights

        if ctx.openScience {
            // Charge: z vs winsorised-EWMA baselines folded over prior nights.
            // Usable after 4 nights (Calibrating until then).
            let charge = ChargeScorer.Input(
                hrv: record.hrv, restingHR: record.restingHR,
                sleepPerformance: record.sleepPerformance,
                respiratoryRate: record.respiratoryRate,
                skinTempC: record.skinTempC, spo2Avg: record.spo2Avg,
                hrvBaseline: Baselines.fold(history.compactMap(\.hrv), cfg: Baselines.hrv),
                rhrBaseline: Baselines.fold(history.compactMap(\.restingHR), cfg: Baselines.restingHR),
                respBaseline: Baselines.fold(history.compactMap(\.respiratoryRate), cfg: Baselines.resp),
                tempBaseline: Baselines.fold(history.compactMap(\.skinTempC), cfg: Baselines.skinTemp))
            if let c = ChargeScorer.score(charge) { record.recovery = c.score }
        } else if baselineReady, record.hrv != nil {
            record.recovery = RecoveryCalculator.compute(recInput, weights: ctx.recoveryWeights).score
        }

        // --- Stress (representative daily reading vs 14-day baseline) ---
        if baselineReady,
           let hrv = record.hrv,
           let hrvMean = rollingMean(history, \.hrv, 14),
           let hrvStd = rollingStd(history, \.hrv, 14), hrvStd > 0,
           let rhrVal = record.restingHR,
           let hrMean = rollingMean(history, \.restingHR, 14),
           let hrStd = rollingStd(history, \.restingHR, 14), hrStd > 0 {
            record.stress = StressCalculator.stress(
                currentHRV: hrv, hrvMean14: hrvMean, hrvStd14: hrvStd,
                currentHR: rhrVal, hrMean14: hrMean, hrStd14: hrStd,
                inWorkoutWindow: false).score
        }

        // --- ACWR + monotony ---
        if let strain = record.dayStrain {
            acwrState = StrainCalculator.updateACWR(previous: acwrState, strainToday: strain)
            let priorStrainDays = history.filter { $0.dayStrain != nil }.count
            record.acwr = priorStrainDays >= 14 ? acwrState?.ratio : nil
        }
        let last7Strain = (history.suffix(6) + [record]).compactMap(\.dayStrain)
        record.monotony = last7Strain.count >= 7
            ? StrainCalculator.monotony(last7Strain: last7Strain).monotony : nil

        // --- Readiness ---
        if let rec = record.recovery {
            record.readiness = ReadinessCalculator.readiness(
                recovery: rec,
                sleepPerformance: record.sleepPerformance ?? rec,
                acwrRatio: record.acwr ?? 0)
        }

        // --- Cognitive readiness (store the day's PEAK for Trends) ---
        if let inputs = FocusInputs.build(for: record, history: history,
                                          wakeMinuteFallback: ctx.wakeMinuteOfDay,
                                          calibrationOffset: ctx.focusCalibrationOffset) {
            let wake = inputs.wakeTime
            let end = Calendar.current.date(byAdding: .hour, value: 16, to: wake) ?? wake
            let curve = CognitiveReadinessCalculator.curve(from: wake, to: end, stepMinutes: 30, inputs: inputs)
            record.cognitiveReadiness = curve.map(\.score).max()
        }

        return record
    }

    // MARK: Fetch helpers (for the UI / coordinator)

    /// Most recent record that actually has a recovery score.
    func latestRecord() -> DailyRecord? {
        var descriptor = FetchDescriptor<DailyRecord>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 60
        guard let records = try? modelContext.fetch(descriptor) else { return nil }
        return records.first { $0.recovery != nil } ?? records.first
    }

    /// The most recent record with any usable data — i.e. "today". Strain
    /// accumulates through the current day, so it should reflect this record,
    /// not the last fully-scored one (which can be yesterday in the morning).
    func todayRecord() -> DailyRecord? {
        var descriptor = FetchDescriptor<DailyRecord>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 60
        guard let records = try? modelContext.fetch(descriptor) else { return nil }
        return records.first { $0.dayStrain != nil || $0.hrv != nil || $0.sleepPerformance != nil }
            ?? records.first
    }

    /// Delete every stored day record (a clean slate). Data re-syncs from the
    /// source on the next refresh.
    func deleteAllData() {
        if let all = try? modelContext.fetch(FetchDescriptor<DailyRecord>()) {
            for record in all { modelContext.delete(record) }
            try? modelContext.save()
        }
        lastRefresh = nil
        lastError = nil
        pendingSync = nil
        hasPendingData = false
        Self.lastSyncEnd = nil        // next sync re-backfills the full window
        Self.nextFetchStart = nil     // force full re-fetch on next sync
        Self.knownEmptyDays = []      // forget which days were empty
    }

    /// Number of nights with usable HRV data (for calibration display).
    func usableNights() -> Int {
        var descriptor = FetchDescriptor<DailyRecord>()
        descriptor.fetchLimit = 400
        guard let records = try? modelContext.fetch(descriptor) else { return 0 }
        return records.filter { $0.hrv != nil }.count
    }

    // MARK: Persistence helpers

    private func upsertRecord(for day: Date) -> DailyRecord {
        let sod = Calendar.current.startOfDay(for: day)
        let descriptor = FetchDescriptor<DailyRecord>(predicate: #Predicate { $0.date == sod })
        if let existing = try? modelContext.fetch(descriptor).first {
            return existing
        }
        let record = DailyRecord(date: sod)
        modelContext.insert(record)
        return record
    }

    // MARK: Aggregation helpers

    nonisolated private static func mean(_ samples: [QuantitySample], _ from: Date, _ to: Date) -> Double? {
        let v = samples.filter { $0.start >= from && $0.start <= to }.map(\.value)
        return v.isEmpty ? nil : Stats.mean(v)
    }

    nonisolated private static func lastValue(_ samples: [QuantitySample], _ from: Date, _ to: Date) -> Double? {
        samples.filter { $0.start >= from && $0.start <= to }.max { $0.start < $1.start }?.value
    }

    nonisolated private static func rollingMean(_ history: [DayValues], _ key: KeyPath<DayValues, Double?>, _ window: Int) -> Double? {
        let vals = history.suffix(window).compactMap { $0[keyPath: key] }
        return vals.isEmpty ? nil : Stats.mean(vals)
    }

    nonisolated private static func rollingStd(_ history: [DayValues], _ key: KeyPath<DayValues, Double?>, _ window: Int) -> Double? {
        let vals = history.suffix(window).compactMap { $0[keyPath: key] }
        return vals.count > 1 ? Stats.stdDev(vals) : nil
    }
}
