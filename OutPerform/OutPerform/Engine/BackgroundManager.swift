//
//  BackgroundManager.swift
//  OutPerform
//
//  Background syncing via BGTaskScheduler. Two tasks:
//   • App-refresh (light, frequent): a quick incremental sync so scores are
//     fresh when you next open the app.
//   • Processing (heavy, occasional): a fuller backfill that's allowed to run
//     longer — used after a first sync / reset to fill in history.
//  Both identifiers are declared in Info.plist under
//  BGTaskSchedulerPermittedIdentifiers.
//

import Foundation
import BackgroundTasks

@MainActor
final class BackgroundManager {
    static let shared = BackgroundManager()
    static let refreshIdentifier = "mamilles.OutPerform.refresh"
    static let processingIdentifier = "mamilles.OutPerform.processing"

    private var engineProvider: (() -> ScoreEngine?)?

    /// Must be called once at launch, before the app finishes launching.
    func register(engineProvider: @escaping () -> ScoreEngine?) {
        self.engineProvider = engineProvider
        // BGAppRefreshTask: light incremental — just the last 2 days.
        // The OS grants ~30 s; pulling 2 days is reliably within budget.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshIdentifier, using: nil) { task in
            MainActor.assumeIsolated { self.handle(task: task, daysBack: 2) }
        }
        // BGProcessingTask: slightly heavier catch-up — last 7 days.
        // Runs when idle/charging; still conservative to avoid memory pressure kills.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingIdentifier, using: nil) { task in
            MainActor.assumeIsolated { self.handle(task: task, daysBack: 7) }
        }
    }

    /// Queue both background tasks. Call at launch and whenever the app is
    /// backgrounded, so the system always has a pending request to run soon.
    func schedule() {
        // Light incremental refresh — allowed to run as soon as ~15 min from now.
        let refresh = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(refresh)

        // Heavier backfill — needs the network, can run a little later.
        let processing = BGProcessingTaskRequest(identifier: Self.processingIdentifier)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(processing)
    }

    private func handle(task: BGTask, daysBack: Int) {
        schedule()   // chain the next one

        // Thread-safe once-caller: BGTask.setTaskCompleted must be called exactly
        // once. Without this guard, the expiration handler and the work task can
        // both call it — Apple documents that as a programming error that may crash.
        let completer = BGTaskCompleter(task: task)

        let work = Task {
            await engineProvider?()?.refresh(daysBack: daysBack)
            // Only complete as success if we weren't cancelled by the expiration handler.
            completer.complete(success: !Task.isCancelled)
        }
        task.expirationHandler = {
            work.cancel()
            completer.complete(success: false)
        }
    }
}

// MARK: - BGTaskCompleter

/// Ensures BGTask.setTaskCompleted is called exactly once regardless of
/// whether the work task finishes normally or the expiration handler fires first.
/// Both paths can race; NSLock makes the first-caller-wins guarantee thread-safe.
private final class BGTaskCompleter: @unchecked Sendable {
    private let task: BGTask
    private var done = false
    private let lock = NSLock()

    init(task: BGTask) { self.task = task }

    func complete(success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        task.setTaskCompleted(success: success)
    }
}
