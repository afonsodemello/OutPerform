//
//  AppModel.swift
//  OutPerform
//
//  Top-level coordinator: owns the active data provider and the score engine,
//  and knows how to switch between Apple Health and Google Health.
//

import Foundation
import SwiftData
import UIKit

@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    var engine: ScoreEngine

    init(modelContext: ModelContext) {
        let settings = AppSettings.shared
        self.settings = settings
        let provider = AppModel.makeProvider(for: settings.dataSource)
        self.engine = ScoreEngine(provider: provider, settings: settings, modelContext: modelContext)
        configureBand()
        WorkoutRecorder.shared.recoverIfNeeded()
    }

    /// Start the Bluetooth link when the band is the source (or one is paired),
    /// and re-score from the stored streams every 15 minutes of live data.
    private func configureBand() {
        let band = BandManager.shared
        band.onScoringTick = { [weak self] in
            guard let self, self.settings.dataSource.usesBand else { return }
            Task { await self.refresh() }
        }
        if settings.dataSource.usesBand || band.isPaired { Task { await band.startWhenReady() } }
    }

    static func makeProvider(for type: DataSourceType) -> HealthDataProvider {
        // Workouts recorded in the Exercise tab join every real source.
        type == .demo ? baseProvider(for: type) : RecordedWorkoutsProvider(base: baseProvider(for: type))
    }

    private static func baseProvider(for type: DataSourceType) -> HealthDataProvider {
        switch type {
        case .appleHealth:  return HealthKitProvider()
        case .googleHealth: return GoogleHealthProvider()
        case .bluetooth:    return BandDataProvider()
        case .combined:     return CombinedDataProvider()
        case .demo:         return DemoDataProvider()
        }
    }

    /// The set of sources feeding the engine changed (new source, a source
    /// toggled, Google signed in, band paired). The engine normally re-fetches
    /// only the last 2 days and treats any day with *some* data as done, so
    /// older days would never pick up what the new source adds (e.g. HRV for
    /// nights that only had sleep). Forget the incremental window so the next
    /// sync re-reads the full 30 days; stored records are merged, not wiped.
    func sourcesChanged() {
        ScoreEngine.nextFetchStart = nil
        ScoreEngine.knownEmptyDays = []
    }

    /// Switch the active source (e.g. from Settings) and rebuild the provider.
    /// Switching between Demo and a real source (in either direction) wipes all
    /// stored records so demo values never contaminate live data and vice versa.
    func switchSource(to type: DataSourceType) {
        let previousSource = settings.dataSource
        if previousSource != type { sourcesChanged() }
        let needsReset = previousSource == .demo || type == .demo
        settings.dataSource = type
        // The band (alone or in "All sources") is scored with the open-science
        // (NOOP-method) model; the other sources keep OutPerform's classic formulas.
        let config = AlgorithmConfig.shared
        let model: ScoringModel = type.usesBand ? .openScience : .outperform
        if config.scoringModel != model {
            config.scoringModel = model
            config.save()
        }
        // Bluetooth starts from the provider's requestAuthorization, after
        // Apple Health has been asked, so the two popups never collide.
        if needsReset {
            engine.deleteAllData()
            WidgetBridge.publish(readiness: nil, recovery: nil, strain: nil,
                                 sleepPerformance: nil, bedtime: nil, calibratingNights: nil)
        }
        engine.setProvider(AppModel.makeProvider(for: type))
    }

    /// Request authorization for the active source, then pull and compute.
    func authorizeAndRefresh() async {
        do {
            try await engine.provider.requestAuthorization()
        } catch {
            engine.lastError = error.localizedDescription
        }
        await withBackgroundTask {
            await self.engine.refresh()
            await self.scheduleBedtimeFromLatest()
        }
    }

    func refresh() async {
        await withBackgroundTask {
            await self.engine.refresh()
            await self.scheduleBedtimeFromLatest()
        }
    }

    /// Banner phase 1: fetch raw data from the provider without computing.
    /// After this, `engine.hasPendingData` is true and the banner offers "Apply".
    func fetchNewData(daysBack: Int = 30) async {
        await withBackgroundTask {
            await self.engine.fetchRaw(daysBack: daysBack)
        }
    }

    /// Banner phase 2: compute scores from staged data and persist.
    func applyPendingData() async {
        await withBackgroundTask {
            await self.engine.applyPending()
            await self.scheduleBedtimeFromLatest()
        }
    }

    /// Run `body` under a UIKit background-task assertion so a sync the user
    /// kicked off keeps running for the system-granted window even if they leave
    /// the app — instead of being suspended the moment the view disappears.
    private func withBackgroundTask(_ body: () async -> Void) async {
        let app = UIApplication.shared
        var taskID: UIBackgroundTaskIdentifier = .invalid
        taskID = app.beginBackgroundTask(withName: "OutPerform.sync") {
            if taskID != .invalid { app.endBackgroundTask(taskID); taskID = .invalid }
        }
        await body()
        if taskID != .invalid { app.endBackgroundTask(taskID); taskID = .invalid }
    }

    /// Pull data on first appearance if nothing has been computed yet.
    func refreshIfEmpty() async {
        if engine.latestRecord() == nil { await refresh() }
    }

    /// Refresh when we have no data, or when the last sync is stale — so opening
    /// the app (or returning to it) later in the day pulls today's data instead of
    /// leaving yesterday's on screen. `lastRefresh` is in-memory, so this also
    /// fires on the first open after each launch.
    ///
    /// Rate-limited by `lastRefreshAttempt` so a broken auth source (e.g. stale
    /// Google tokens after a reinstall) can't trigger an infinite retry loop.
    func refreshIfStale(olderThan seconds: TimeInterval = 60) async {
        // Always respect a minimum gap between attempts regardless of outcome.
        if let attempt = engine.lastRefreshAttempt,
           Date().timeIntervalSince(attempt) < seconds { return }
        guard engine.latestRecord() != nil, let last = engine.lastRefresh else {
            await refresh(); return
        }
        if Date().timeIntervalSince(last) > seconds { await refresh() }
    }

    /// Early-illness nudge: two or more of RHR↑ / HRV↓ / temp↑ / resp↑ over the
    /// last 2 days vs a ~28-day baseline. Nil when nothing fires.
    func illnessSignal() -> IllnessSignal? {
        var descriptor = FetchDescriptor<DailyRecord>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 31
        guard let records = try? engine.modelContextForReads.fetch(descriptor) else { return nil }
        let days = records.reversed().map {
            IllnessWatch.Day(restingHR: $0.restingHR, hrv: $0.hrv, skinTempC: $0.skinTempC, resp: $0.respiratoryRate)
        }
        return IllnessWatch.evaluate(Array(days))
    }

    /// Wipe all stored data and clear the widgets.
    func resetAllData() {
        engine.deleteAllData()
        WidgetBridge.publish(readiness: nil, recovery: nil, strain: nil,
                             sleepPerformance: nil, bedtime: nil, calibratingNights: nil)
    }

    /// Recompute tonight's recommended bedtime, (re)schedule the reminder, and
    /// publish the latest scores to the widgets.
    private func scheduleBedtimeFromLatest() async {
        let record = engine.latestRecord()
        var bedtime: Date?
        if let need = record?.sleepNeedMin {
            bedtime = SleepNeedCalculator.bedtime(
                desiredWake: settings.desiredWakeDate(),
                needMinutes: need,
                target: settings.performanceTarget,
                sleepLatencyMin: settings.sleepLatencyMin)
            if let bedtime { NotificationManager.shared.scheduleBedtimeReminder(at: bedtime) }
        }

        // Recovery/Readiness/Sleep reflect your last fully-scored night; Strain is
        // today's live, accumulating value (matches the Today tab).
        let today = engine.todayRecord()
        let nights = engine.usableNights()
        WidgetBridge.publish(
            readiness: record?.readiness,
            recovery: record?.recovery,
            strain: today?.dayStrain,
            sleepPerformance: today?.sleepPerformance ?? record?.sleepPerformance,
            bedtime: bedtime,
            calibratingNights: record?.recovery == nil ? nights : nil)
    }
}
