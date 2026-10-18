//
//  AICoach.swift
//  OutPerform
//
//  The optional AI coach: a daily brief and a chat, answered by the provider
//  you pick (Anthropic or OpenAI) with your own API key.
//
//  Privacy:
//   • Off until you choose a provider and add a key. The key lives in the
//     iPhone's Keychain.
//   • Your health data is sent only if you turn on "Share my health data"
//     (off by default), and then only as a compact summary of daily scores.
//     Raw heart rate, heartbeats, GPS routes and device IDs are never sent.
//   • The conversation is stored on this iPhone. What you send is subject to
//     the provider's own data policies.
//

import Foundation
import Observation

@Observable
final class AICoach {
    static let shared = AICoach()

    // MARK: Settings

    /// nil = coach off.
    var provider: AIProviderKind? { didSet { defaults.set(provider?.rawValue, forKey: Keys.provider) } }
    var shareHealthData: Bool { didSet { defaults.set(shareHealthData, forKey: Keys.share) } }
    var includeWorkouts: Bool { didSet { defaults.set(includeWorkouts, forKey: Keys.workouts) } }
    /// Write the daily brief automatically the first time you open Today each day.
    var autoBrief: Bool { didSet { defaults.set(autoBrief, forKey: Keys.autoBrief) } }

    func model(for p: AIProviderKind) -> String {
        defaults.string(forKey: Keys.model + p.rawValue) ?? p.defaultModel
    }

    func setModel(_ m: String, for p: AIProviderKind) {
        defaults.set(m, forKey: Keys.model + p.rawValue)
        modelRevision += 1
    }

    /// Bumped when a model changes so views refresh.
    private(set) var modelRevision = 0

    func apiKey(for p: AIProviderKind) -> String? { Keychain.get(Keys.keychain + p.rawValue) }

    func setAPIKey(_ key: String?, for p: AIProviderKind) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { Keychain.delete(Keys.keychain + p.rawValue) }
        else { Keychain.set(trimmed, for: Keys.keychain + p.rawValue) }
        keyRevision += 1
    }

    private(set) var keyRevision = 0

    var isConfigured: Bool {
        _ = keyRevision
        guard let p = provider, let k = apiKey(for: p) else { return false }
        return !k.isEmpty
    }

    // MARK: State

    private(set) var messages: [AIMessage] = []
    private(set) var brief: (date: Date, text: String)?
    private(set) var isResponding = false
    private(set) var isBriefing = false
    private(set) var streamingText = ""
    private(set) var briefStreamingText = ""
    var lastError: String?

    /// Older turns are kept on screen but not re-sent, to bound cost.
    static let maxHistorySent = 20

    private var currentTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    private let fileURL: URL

    private enum Keys {
        static let provider = "ai.provider"
        static let share = "ai.shareHealthData"
        static let workouts = "ai.includeWorkouts"
        static let autoBrief = "ai.autoBrief"
        static let model = "ai.model."
        static let keychain = "ai.key."
        static let briefDate = "ai.brief.date"
        static let briefText = "ai.brief.text"
    }

    private init() {
        provider = AIProviderKind(rawValue: defaults.string(forKey: Keys.provider) ?? "")
        shareHealthData = defaults.bool(forKey: Keys.share)
        includeWorkouts = defaults.object(forKey: Keys.workouts) as? Bool ?? true
        autoBrief = defaults.bool(forKey: Keys.autoBrief)
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("conversation.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([AIMessage].self, from: data) { messages = saved }
        if let d = defaults.object(forKey: Keys.briefDate) as? Date, let t = defaults.string(forKey: Keys.briefText) {
            brief = (d, t)
        }
    }

    var hasTodaysBrief: Bool {
        guard let b = brief else { return false }
        return Calendar.current.isDateInToday(b.date)
    }

    // MARK: Chat

    /// Send a question. `healthSummary` is used only when sharing is on.
    func send(_ text: String, healthSummary: @escaping () -> String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding, let client = makeClient() else {
            if makeClient() == nil { lastError = AIError.missingKey.localizedDescription }
            return
        }
        messages.append(AIMessage(role: .user, text: question))
        save()
        lastError = nil
        isResponding = true
        streamingText = ""
        let system = systemPrompt(healthSummary)
        let history = Array(messages.suffix(Self.maxHistorySent))
        currentTask = Task {
            do {
                for try await chunk in client.stream(system: system, messages: history) {
                    streamingText += chunk
                }
                finishReply()
            } catch is CancellationError {
                finishReply()
            } catch {
                let partial = streamingText
                streamingText = ""
                if !partial.isEmpty, !(error is AIError && isRefusal(error)) {
                    messages.append(AIMessage(role: .assistant, text: partial))
                }
                lastError = error.localizedDescription
                isResponding = false
                save()
            }
        }
    }

    private func isRefusal(_ e: Error) -> Bool {
        if case .refused = e as? AIError { return true }
        return false
    }

    private func finishReply() {
        let text = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { messages.append(AIMessage(role: .assistant, text: text)) }
        streamingText = ""
        isResponding = false
        save()
    }

    func stop() {
        currentTask?.cancel()
    }

    func clearConversation() {
        stop()
        messages.removeAll()
        streamingText = ""
        lastError = nil
        save()
    }

    // MARK: Daily brief

    func generateBrief(healthSummary: @escaping () -> String) {
        guard !isBriefing, let client = makeClient() else { return }
        isBriefing = true
        briefStreamingText = ""
        lastError = nil
        let system = systemPrompt(healthSummary)
        Task {
            do {
                for try await chunk in client.stream(system: system,
                                                     messages: [AIMessage(role: .user, text: CoachContext.briefRequest)]) {
                    briefStreamingText += chunk
                }
                let text = briefStreamingText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    brief = (Date(), text)
                    defaults.set(Date(), forKey: Keys.briefDate)
                    defaults.set(text, forKey: Keys.briefText)
                }
            } catch {
                lastError = error.localizedDescription
            }
            briefStreamingText = ""
            isBriefing = false
        }
    }

    /// Called when Today appears.
    func autoBriefIfNeeded(healthSummary: @escaping () -> String) {
        guard autoBrief, shareHealthData, isConfigured, !hasTodaysBrief, !isBriefing else { return }
        generateBrief(healthSummary: healthSummary)
    }

    // MARK: Helpers

    private func makeClient() -> AIClient? {
        guard let p = provider, let key = apiKey(for: p), !key.isEmpty else { return nil }
        return AIClient(provider: p, apiKey: key, model: model(for: p))
    }

    private func systemPrompt(_ summary: () -> String) -> String {
        if shareHealthData {
            return CoachContext.systemPrompt + "\n\nThe user's recent data from OutPerform:\n\n" + summary()
        }
        return CoachContext.systemPrompt
            + "\n\nThe user has not shared their health data with you. Give general guidance, and mention once "
            + "that they can turn on \"Share my health data\" in Settings → AI coach for personalised answers."
    }

    private func save() {
        if let data = try? JSONEncoder().encode(messages) {
            try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        }
    }
}
