//
//  OutPerformApp.swift
//  OutPerform
//
//  Created by Afonso de Mello on 07/06/2026.
//

import SwiftUI
import SwiftData

@main
struct OutPerformApp: App {
    let container: ModelContainer
    @State private var appModel: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Purge stale OAuth tokens left over from a previous install before
        // anything else runs — prevents the infinite-retry loop on Google Health.
        Keychain.clearIfFreshInstall()

        let container = try! ModelContainer(for: DailyRecord.self, FocusTest.self, DailyFeedback.self)
        self.container = container
        let model = AppModel(modelContext: container.mainContext)
        _appModel = State(initialValue: model)

        // Register background refresh before launch completes.
        BackgroundManager.shared.register(engineProvider: { [weak model] in model?.engine })
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .environment(appModel.settings)
                .environment(AlgorithmConfig.shared)
                .task {
                    await NotificationManager.shared.requestAuthorization()
                    NotificationManager.shared.scheduleSyncReminders(count: appModel.settings.syncReminderCount)
                    BackgroundManager.shared.schedule()
                }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            // Re-arm background sync each time we leave the foreground, so the
            // system always has a fresh pending request to run while we're away.
            if phase == .background { BackgroundManager.shared.schedule() }
        }
    }
}
