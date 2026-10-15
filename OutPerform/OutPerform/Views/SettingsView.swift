//
//  SettingsView.swift
//  OutPerform
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \DailyRecord.date, order: .reverse) private var records: [DailyRecord]

    @State private var working = false
    @State private var message: String?
    @State private var showGoogleConnect = false
    @State private var showResetConfirm = false
    @State private var exportFile: ExportFile?

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section("Data source") {
                    Picker("Source", selection: Binding(
                        get: { settings.dataSource },
                        set: { newValue in
                            appModel.switchSource(to: newValue)
                            if newValue == .googleHealth {
                                showGoogleConnect = true        // needs interactive sign-in
                            } else if newValue == .demo {
                                Task { working = true; await appModel.refresh(); working = false }
                            } else {
                                Task { await reconnect() }
                            }
                        })) {
                        ForEach(DataSourceType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Text(settings.dataSource.detail).font(.caption).foregroundStyle(.secondary)
                    if settings.dataSource == .bluetooth {
                        NavigationLink {
                            BandView()
                        } label: {
                            Label(BandManager.shared.pairedName ?? "Pair your band",
                                  systemImage: "dot.radiowaves.left.and.right")
                        }
                    }
                    if settings.dataSource == .googleHealth {
                        Button {
                            showGoogleConnect = true
                        } label: {
                            Label(GoogleAuthManager.shared.isSignedIn ? "Manage Google connection" : "Sign in with Google",
                                  systemImage: "g.circle.fill")
                        }
                    }
                    if working { ProgressView() }
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }

                Section("Profile") {
                    DatePicker("Date of birth", selection: $settings.birthDate,
                               in: ...Date(), displayedComponents: .date)
                    LabeledContent("Age", value: "\(settings.age)")
                    Picker("Biological sex", selection: $settings.biologicalSex) {
                        ForEach(BiologicalSex.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Stepper(value: $settings.weightKg, in: 30...250, step: 1) {
                        LabeledContent("Weight", value: "\(Int(settings.weightKg)) kg")
                    }
                    Stepper(value: $settings.heightCm, in: 120...230, step: 1) {
                        LabeledContent("Height", value: "\(Int(settings.heightCm)) cm")
                    }
                }

                Section("Sleep planner") {
                    Picker("Performance target", selection: $settings.performanceTarget) {
                        ForEach(SleepNeedCalculator.PerformanceTarget.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    HStack {
                        Text("Sleep latency")
                        Spacer()
                        Text("\(Int(settings.sleepLatencyMin)) min").foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.sleepLatencyMin, in: 0...45, step: 5)
                }

                Section {
                    Button {
                        Task { working = true; await appModel.fetchNewData(); working = false }
                    } label: { Label("Sync now", systemImage: "arrow.clockwise") }
                    if let last = appModel.engine.lastRefresh {
                        Text("Last sync: \(last.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Stepper(value: Binding(
                        get: { settings.syncReminderCount },
                        set: { v in
                            settings.syncReminderCount = v
                            NotificationManager.shared.scheduleSyncReminders(count: v)
                        }), in: 0...10) {
                        HStack {
                            Text("Daily sync reminders")
                            Spacer()
                            Text(settings.syncReminderCount == 0 ? "Off"
                                                                 : "\(settings.syncReminderCount)×")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if settings.syncReminderCount > 0 {
                        Text("Notified at: \(reminderTimes(count: settings.syncReminderCount))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("OutPerform reminds you to open the app and sync so your scores stay accurate. Reminders are spread evenly from 8 AM to 8 PM.")
                }

                Section {
                    NavigationLink {
                        AdvancedSettingsView()
                    } label: {
                        Label("Advanced — change the formulas", systemImage: "slider.horizontal.3")
                    }
                } footer: {
                    Text("Re-weight recovery and sleep, tune the strain curve, pick a max-HR method.")
                }

                Section {
                    Button {
                        if let url = try? DataExporter.makeTextFile(from: records) {
                            exportFile = ExportFile(url: url)
                        }
                    } label: {
                        Label("Export all data (.txt)", systemImage: "square.and.arrow.up")
                    }
                    .disabled(records.isEmpty)

                    Button(role: .destructive) {
                        showResetConfirm = true
                    } label: {
                        Label("Reset all data", systemImage: "trash")
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Export writes every day's metrics to a text file you can save or share. Reset wipes all stored data — it re-syncs from your source on the next refresh.")
                }

                Section("About") {
                    Link(destination: URL(string: "https://outperform.afonsodemello.com")!) {
                        Label("Website", systemImage: "safari")
                    }
                    Link(destination: URL(string: "https://outperform.afonsodemello.com/science.html")!) {
                        Label("Science & Sources", systemImage: "book.pages")
                    }
                    Link(destination: URL(string: "https://outperform.afonsodemello.com/privacy.html")!) {
                        Label("Privacy policy", systemImage: "lock.shield")
                    }
                    Link(destination: URL(string: "https://revolut.me/afonsodemello")!) {
                        Label("Support OutPerform — donate via Revolut", systemImage: "heart.fill")
                    }
                    LabeledContent("Privacy", value: "On-device only")
                    Text("All scores are computed locally. Nothing leaves your phone except the sign-in to your chosen source.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Not a medical device. Screening features are informational and never a diagnosis.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showGoogleConnect) {
                GoogleConnectView()
            }
            .sheet(item: $exportFile) { file in
                ShareSheet(items: [file.url])
            }
            .alert("Reset all data?", isPresented: $showResetConfirm) {
                Button("Reset", role: .destructive) { appModel.resetAllData() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This permanently deletes all stored metrics on this device. It can't be undone, but data re-syncs from your source on the next refresh.")
            }
        }
    }

    private func reconnect() async {
        working = true; message = nil
        await appModel.authorizeAndRefresh()
        message = appModel.engine.lastError
        working = false
    }

    /// Returns a formatted list of the times at which sync reminders will fire.
    private func reminderTimes(count: Int) -> String {
        let fmt = DateFormatter(); fmt.timeStyle = .short
        let cal = Calendar.current
        return (0..<count).map { i in
            let fraction = count == 1 ? 0.5 : Double(i) / Double(count - 1)
            let mins = Int((8.0 + fraction * 12.0) * 60)
            let d = cal.date(bySettingHour: mins / 60, minute: mins % 60, second: 0, of: Date())!
            return fmt.string(from: d)
        }.joined(separator: ", ")
    }
}
