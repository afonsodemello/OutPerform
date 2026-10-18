//
//  AICoachViews.swift
//  OutPerform
//
//  The AI coach on the Today tab (daily brief + quick question), the chat
//  screen, and its settings.
//

import SwiftUI

// MARK: - Today card

struct AICoachCard: View {
    @Environment(AppModel.self) private var appModel
    @State private var coach = AICoach.shared
    @State private var question = ""
    @State private var showChat = false
    @State private var showSettings = false

    var body: some View {
        SectionCard(title: "AI coach", systemImage: "sparkles") {
            if coach.isConfigured {
                configured
            } else {
                Text("Get a daily brief and ask questions about your recovery, sleep and training, answered by Claude or ChatGPT using your own API key.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button { showSettings = true } label: {
                    Label("Set up AI coach", systemImage: "key.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .sheet(isPresented: $showChat) { AICoachChatView() }
        .sheet(isPresented: $showSettings) { NavigationStack { AICoachSettingsView() } }
        .task { coach.autoBriefIfNeeded(healthSummary: appModel.coachHealthSummary) }
    }

    @ViewBuilder private var configured: some View {
        // Brief
        if coach.isBriefing {
            HStack(alignment: .top, spacing: 8) {
                ProgressView().controlSize(.small)
                Text(coach.briefStreamingText.isEmpty ? "Writing today's brief…" : markdown(coach.briefStreamingText))
                    .font(.subheadline)
            }
        } else if coach.hasTodaysBrief, let brief = coach.brief {
            Text(markdown(brief.text)).font(.subheadline)
            HStack {
                Text("Brief from \(brief.date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { coach.generateBrief(healthSummary: appModel.coachHealthSummary) }
                    .font(.caption)
            }
        } else {
            Button {
                coach.generateBrief(healthSummary: appModel.coachHealthSummary)
            } label: {
                Label("Get today's brief", systemImage: "text.bubble").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            if !coach.shareHealthData {
                Text("Turn on \"Share my health data\" in AI coach settings for a brief based on your numbers.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }

        // Quick question
        HStack(spacing: 8) {
            TextField("Ask your coach…", text: $question, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit(ask)
            Button(action: ask) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || coach.isResponding)
                .accessibilityLabel("Send")
        }
        HStack {
            Button {
                showChat = true
            } label: {
                Label(coach.messages.isEmpty ? "Open chat" : "Continue chat (\(coach.messages.count))",
                      systemImage: "bubble.left.and.bubble.right")
            }
            .font(.caption)
            Spacer()
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .font(.caption)
                .accessibilityLabel("AI coach settings")
        }
        if let err = coach.lastError, !showChat {
            Text(err).font(.caption).foregroundStyle(.red)
        }
    }

    private func ask() {
        let q = question
        question = ""
        coach.send(q, healthSummary: appModel.coachHealthSummary)
        showChat = true
    }
}

/// Inline markdown (bold, italics, links) with line breaks kept.
func markdown(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(s)
}

// MARK: - Chat

struct AICoachChatView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var coach = AICoach.shared
    @State private var input = ""
    @State private var confirmClear = false
    @FocusState private var focused: Bool

    private let suggestions = [
        "How hard should I train today?",
        "Why is my recovery where it is?",
        "How can I sleep better tonight?",
        "Summarise my last week",
    ]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if coach.messages.isEmpty && !coach.isResponding { emptyState }
                        ForEach(coach.messages) { m in bubble(m.text, mine: m.role == .user).id(m.id) }
                        if coach.isResponding {
                            Group {
                                if coach.streamingText.isEmpty {
                                    HStack { ProgressView(); Text("Thinking…").foregroundStyle(.secondary); Spacer() }
                                } else {
                                    bubble(coach.streamingText, mine: false)
                                }
                            }
                            .id("streaming")
                        }
                        if let err = coach.lastError {
                            Label(err, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("error")
                        }
                    }
                    .padding()
                }
                .onChange(of: coach.streamingText) { _, _ in proxy.scrollTo("streaming", anchor: .bottom) }
                .onChange(of: coach.messages.count) { _, _ in
                    if let last = coach.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onAppear {
                    if let last = coach.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
            .navigationTitle("AI coach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        NavigationLink { AICoachSettingsView() } label: { Label("Settings", systemImage: "gearshape") }
                        Button(role: .destructive) { confirmClear = true } label: {
                            Label("Clear conversation", systemImage: "trash")
                        }
                        .disabled(coach.messages.isEmpty)
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .confirmationDialog("Clear the conversation?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear", role: .destructive) { coach.clearConversation() }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.tint)
            Text("Ask about your recovery, sleep, training or today's plan.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            if let p = coach.provider {
                Text("\(p.displayName) · \(coach.model(for: p))\(coach.shareHealthData ? " · sees your daily scores" : " · your data isn't shared")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(suggestions, id: \.self) { s in
                Button(s) { coach.send(s, healthSummary: appModel.coachHealthSummary) }
                    .buttonStyle(.bordered)
                    .disabled(!coach.isConfigured)
            }
        }
        .padding(.top, 40)
    }

    private func bubble(_ text: String, mine: Bool) -> some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            Text(markdown(text))
                .textSelection(.enabled)
                .padding(12)
                .background(mine ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(mine ? .white : .primary)
            if !mine { Spacer(minLength: 40) }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(coach.isConfigured ? "Message your coach" : "Set up the AI coach in Settings first",
                      text: $input, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .disabled(!coach.isConfigured)
            if coach.isResponding {
                Button { coach.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                    .accessibilityLabel("Stop")
            } else {
                Button {
                    coach.send(input, healthSummary: appModel.coachHealthSummary)
                    input = ""
                } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || !coach.isConfigured)
                .accessibilityLabel("Send")
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }
}

// MARK: - Settings

struct AICoachSettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var coach = AICoach.shared
    @State private var keyInput = ""
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var modelError: String?
    @State private var confirmClear = false

    var body: some View {
        @Bindable var coach = coach
        Form {
            Section {
                Picker("Provider", selection: $coach.provider) {
                    Text("Off").tag(AIProviderKind?.none)
                    ForEach(AIProviderKind.allCases) { Text($0.displayName).tag(AIProviderKind?.some($0)) }
                }
            } footer: {
                Text("Requests go straight from your iPhone to the provider, using your own API key. OutPerform runs no server in between. The provider bills your account for usage.")
            }

            if let p = coach.provider {
                keySection(p)
                modelSection(p)
            }

            Section {
                Toggle("Share my health data", isOn: $coach.shareHealthData)
                if coach.shareHealthData {
                    Toggle("Include recorded workouts", isOn: $coach.includeWorkouts)
                    Toggle("Write a brief automatically each day", isOn: $coach.autoBrief)
                    NavigationLink("Preview what's sent") {
                        ScrollView {
                            Text(appModel.coachHealthSummary())
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .padding()
                        }
                        .navigationTitle("Shared with the AI")
                    }
                }
            } header: {
                Text("Your data")
            } footer: {
                Text(coach.shareHealthData
                     ? "Each request includes a text summary of your last 14 days of scores (recovery, strain, sleep, HRV, resting HR, breathing…), your profile basics and zones. Raw heart rate, heartbeats, GPS routes and device IDs are never sent. The provider's privacy policy applies."
                     : "Off: the coach only sees what you type, so its answers are general.")
            }

            Section {
                Button("Clear conversation", role: .destructive) { confirmClear = true }
                    .disabled(coach.messages.isEmpty)
            } footer: {
                Text("Your conversation is stored only on this iPhone. Not medical advice.")
            }
        }
        .navigationTitle("AI coach")
        .confirmationDialog("Clear the conversation?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { coach.clearConversation() }
        }
        .onChange(of: coach.provider) { _, _ in models = []; modelError = nil; keyInput = "" }
    }

    @ViewBuilder private func keySection(_ p: AIProviderKind) -> some View {
        let saved = coach.apiKey(for: p)
        Section {
            if let saved, !saved.isEmpty {
                LabeledContent("API key", value: "••••" + saved.suffix(4))
                Button("Remove key", role: .destructive) { coach.setAPIKey(nil, for: p); models = [] }
            } else {
                SecureField(p.keyPlaceholder, text: $keyInput)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Save key") {
                    coach.setAPIKey(keyInput, for: p)
                    keyInput = ""
                    Task { await loadModels(p) }
                }
                .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                Link("Get an API key", destination: p.consoleURL)
            }
        } header: {
            Text("API key")
        } footer: {
            Text("Stored in the iPhone's Keychain.")
        }
    }

    @ViewBuilder private func modelSection(_ p: AIProviderKind) -> some View {
        let current = coach.model(for: p)
        Section {
            if models.isEmpty {
                LabeledContent("Model", value: current)
            } else {
                Picker("Model", selection: Binding(get: { current }, set: { coach.setModel($0, for: p) })) {
                    if !models.contains(current) { Text(current).tag(current) }
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
            }
            Button {
                Task { await loadModels(p) }
            } label: {
                HStack {
                    Text("Load available models")
                    if loadingModels { Spacer(); ProgressView() }
                }
            }
            .disabled(loadingModels || (coach.apiKey(for: p) ?? "").isEmpty)
            if let modelError { Text(modelError).font(.caption).foregroundStyle(.red) }
            if current != p.defaultModel {
                Button("Use default (\(p.defaultModel))") { coach.setModel(p.defaultModel, for: p) }
                    .font(.caption)
            }
        } header: {
            Text("Model")
        } footer: {
            Text(p == .anthropic
                 ? "Default: Claude Opus 5.5. Larger models give better answers but cost more per message."
                 : "Default: GPT-5. Larger models give better answers but cost more per message.")
        }
    }

    private func loadModels(_ p: AIProviderKind) async {
        guard let key = coach.apiKey(for: p) else { return }
        loadingModels = true
        modelError = nil
        do {
            models = try await AIClient(provider: p, apiKey: key, model: coach.model(for: p)).listModels()
            if models.isEmpty { modelError = "No chat models found for this key." }
        } catch {
            modelError = error.localizedDescription
        }
        loadingModels = false
    }
}
