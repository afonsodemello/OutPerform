//
//  OnboardingView.swift
//  OutPerform
//
//  Welcome → choose data source → grant access → profile.
//

import SwiftUI

struct OnboardingView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppModel.self) private var appModel

    @State private var step = 0
    @State private var selectedSource: DataSourceType = .appleHealth
    @State private var birthDate = Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date()
    @State private var sex: BiologicalSex = .other
    @State private var wakeTime = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date())!
    @State private var authorizing = false
    @State private var authError: String?
    @State private var showGoogleConnect = false

    static let oldestBirthDate = Calendar.current.date(byAdding: .year, value: -120, to: Date()) ?? Date.distantPast

    var body: some View {
        TabView(selection: $step) {
            welcome.tag(0)
            sourcePicker.tag(1)
            profile.tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .ignoresSafeArea(.keyboard)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "bolt.heart.fill")
                .font(.system(size: 72)).foregroundStyle(.tint)
            Text("OutPerform").font(.largeTitle.bold())
            Text("Recovery, strain, sleep and readiness — computed entirely on your device from your health data, for free.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Spacer()
            Button("Get started") { withAnimation { step = 1 } }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Spacer()
        }
    }

    private var sourcePicker: some View {
        VStack(spacing: 16) {
            Text("Where's your data?")
                .font(.title2.bold()).padding(.top, 40)
            Text("Pick a source. You can change this any time in Settings.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal)

            ForEach(DataSourceType.allCases, id: \.self) { source in
                Button { selectedSource = source } label: {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: source.systemImage)
                            .font(.title2).frame(width: 32)
                            .foregroundStyle(selectedSource == source ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.displayName).font(.headline)
                            Text(source.detail).font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                        if selectedSource == source {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                        }
                    }
                    .padding(14)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .stroke(selectedSource == source ? Color.accentColor : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
            }

            if let authError {
                Text(authError).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }

            Spacer()
            Button { withAnimation { step = 2 } } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).padding(.horizontal)
        }
    }

    private var profile: some View {
        Form {
            Section("About you") {
                DatePicker("Date of birth", selection: $birthDate,
                           in: Self.oldestBirthDate...Date(), displayedComponents: .date)
                Picker("Biological sex", selection: $sex) {
                    ForEach(BiologicalSex.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Text("Used for max-HR (Gellish) and VO₂ max norms.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sleep") {
                DatePicker("Wake time", selection: $wakeTime, displayedComponents: .hourAndMinute)
                Text("Drives your bedtime recommendation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button {
                    Task { await finish() }
                } label: {
                    HStack {
                        if authorizing { ProgressView().padding(.trailing, 6) }
                        Text(authorizing ? "Connecting…" : "Finish & connect \(selectedSource.displayName)")
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(authorizing)
            }
        }
        .sheet(isPresented: $showGoogleConnect) {
            GoogleConnectView(onConnected: { settings.hasOnboarded = true })
        }
    }

    private func saveProfile() {
        let cal = Calendar.current
        settings.birthDate = birthDate
        settings.biologicalSex = sex
        settings.wakeMinuteOfDay = cal.component(.hour, from: wakeTime) * 60 + cal.component(.minute, from: wakeTime)
    }

    private func finish() async {
        saveProfile()
        // Google needs an interactive sign-in — present its sheet.
        if selectedSource == .googleHealth {
            appModel.switchSource(to: .googleHealth)
            showGoogleConnect = true
            return
        }
        // Demo needs no authorization — just switch and sync.
        if selectedSource == .demo {
            appModel.switchSource(to: .demo)
            settings.hasOnboarded = true
            Task { await appModel.refresh() }
            return
        }
        authorizing = true
        authError = nil
        appModel.switchSource(to: selectedSource)
        // Only wait for the permission prompt — not the whole first sync. Once
        // access is granted we drop straight into the app and let the data load
        // in the background (the Today tab shows the loading state).
        do {
            try await appModel.engine.provider.requestAuthorization()
        } catch {
            authError = error.localizedDescription
            authorizing = false
            return
        }
        settings.hasOnboarded = true
        Task { await appModel.refresh() }   // background sync, shown in Today
    }
}
