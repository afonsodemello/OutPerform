//
//  SyncNowIntent.swift
//  OutPerformWidget
//

import AppIntents
import BackgroundTasks
import WidgetKit

struct SyncNowIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync OutPerform"
    static var description = IntentDescription("Fetch the latest health data in the background.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        // Ask the system to run the main app's BGProcessingTask ASAP.
        // BackgroundManager handles the task identifier and calls engine.refresh().
        let request = BGProcessingTaskRequest(identifier: "mamilles.OutPerform.processing")
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = .now
        try? BGTaskScheduler.shared.submit(request)
        // Reload timelines so the "last synced" timestamp refreshes once the task completes.
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
