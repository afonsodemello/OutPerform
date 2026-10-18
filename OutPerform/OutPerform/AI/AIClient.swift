//
//  AIClient.swift
//  OutPerform
//
//  Talks directly to the AI provider you choose, with your own API key.
//  There's no OutPerform server in between: requests go from this iPhone to
//  Anthropic or OpenAI.
//
//  • Anthropic: Messages API (POST /v1/messages), streamed over SSE.
//    Default model Claude Opus 5.5. Requests opt into Anthropic's server-side
//    refusal fallback on the models that support it, so a safety decline is
//    retried on Anthropic's recommended fallback model instead of failing.
//  • OpenAI: Chat Completions (POST /v1/chat/completions), streamed over SSE.
//  • Both: the model list comes from the provider's own /v1/models, so new
//    models show up without an app update.
//

import Foundation

enum AIProviderKind: String, Codable, CaseIterable, Identifiable {
    case anthropic, openai
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openai:    return "OpenAI (ChatGPT)"
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-opus-5-5"
        case .openai:    return "gpt-5"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic: return "sk-ant-…"
        case .openai:    return "sk-…"
        }
    }

    var consoleURL: URL {
        switch self {
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")!
        case .openai:    return URL(string: "https://platform.openai.com/api-keys")!
        }
    }
}

struct AIMessage: Codable, Hashable, Identifiable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID()
    var role: Role
    var text: String
    var date = Date()
}

enum AIError: LocalizedError {
    case missingKey
    case http(Int, String)
    case refused(String?)
    case truncated
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Add your API key in Settings → AI coach."
        case .http(let code, let message):
            switch code {
            case 401: return "The API key was rejected. Check it in Settings → AI coach."
            case 429: return "Rate limit or quota reached at the provider. Try again in a moment."
            case 529, 503: return "The provider is overloaded right now. Try again shortly."
            default: return message.isEmpty ? "The provider returned an error (\(code))." : message
            }
        case .refused(let category):
            return "The model declined to answer this\(category.map { " (\($0))" } ?? ""). Try rephrasing."
        case .truncated:
            return "The answer was cut off because it hit the length limit."
        case .badResponse:
            return "Couldn't read the provider's response."
        }
    }
}

struct AIClient {
    let provider: AIProviderKind
    let apiKey: String
    let model: String

    static let maxTokens = 16000

    // MARK: Chat (streaming)

    /// Stream the assistant's reply as text chunks.
    func stream(system: String, messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw AIError.missingKey }
                    let request = try makeChatRequest(system: system, messages: messages)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw AIError.badResponse }
                    guard http.statusCode == 200 else {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw AIError.http(http.statusCode, Self.errorMessage(from: body))
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let chunk = try parse(event: event) { continuation.yield(chunk) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeChatRequest(system: String, messages: [AIMessage]) throws -> URLRequest {
        var req: URLRequest
        var body: [String: Any]
        let history = messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        switch provider {
        case .anthropic:
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": model,
                "max_tokens": Self.maxTokens,
                "stream": true,
                "system": system,
                "messages": history,
            ]
            // Effort controls answer depth/cost. Coaching chat doesn't need deep
            // reasoning, so pin it explicitly (models default differently).
            if Self.anthropicSupportsEffort(model) {
                body["output_config"] = ["effort": "medium"]
            }
            // Server-side refusal fallback: a classifier decline is retried on
            // Anthropic's recommended model for that category, in the same call.
            if Self.anthropicSupportsFallback(model) {
                body["fallbacks"] = "default"
                req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            }
        case .openai:
            req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            body = [
                "model": model,
                "stream": true,
                "max_completion_tokens": Self.maxTokens,
                "messages": [["role": "system", "content": system]] + history,
            ]
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Returns the next text chunk, or nil for events that carry none.
    private func parse(event: [String: Any]) throws -> String? {
        switch provider {
        case .anthropic:
            switch event["type"] as? String {
            case "content_block_delta":
                // Only visible text; thinking blocks stream separately and are ignored.
                let delta = event["delta"] as? [String: Any]
                return delta?["type"] as? String == "text_delta" ? delta?["text"] as? String : nil
            case "message_delta":
                let delta = event["delta"] as? [String: Any]
                switch delta?["stop_reason"] as? String {
                case "refusal":
                    let details = delta?["stop_details"] as? [String: Any]
                    throw AIError.refused(details?["category"] as? String)
                case "max_tokens":
                    throw AIError.truncated
                default:
                    return nil
                }
            case "error":
                let err = event["error"] as? [String: Any]
                throw AIError.http(0, err?["message"] as? String ?? "The provider reported an error.")
            default:
                return nil
            }
        case .openai:
            let choice = (event["choices"] as? [[String: Any]])?.first
            if choice?["finish_reason"] as? String == "content_filter" { throw AIError.refused(nil) }
            if choice?["finish_reason"] as? String == "length" { throw AIError.truncated }
            return (choice?["delta"] as? [String: Any])?["content"] as? String
        }
    }

    // MARK: Models

    /// Chat-capable models the key can use, newest first.
    func listModels() async throws -> [String] {
        guard !apiKey.isEmpty else { throw AIError.missingKey }
        var req: URLRequest
        switch provider {
        case .anthropic:
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openai:
            req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw AIError.badResponse }
        guard http.statusCode == 200 else {
            throw AIError.http(http.statusCode, Self.errorMessage(from: String(decoding: data, as: UTF8.self)))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { throw AIError.badResponse }
        switch provider {
        case .anthropic:
            // Already newest-first.
            return items.compactMap { $0["id"] as? String }
        case .openai:
            // Keep chat models; drop embeddings, audio, image, moderation, etc.
            let skip = ["embedding", "whisper", "tts", "dall-e", "image", "audio", "realtime",
                        "moderation", "transcribe", "search", "davinci", "babbage", "instruct"]
            return items
                .filter { m in
                    let id = (m["id"] as? String ?? "").lowercased()
                    return (id.hasPrefix("gpt") || id.hasPrefix("o") || id.hasPrefix("chatgpt"))
                        && !skip.contains { id.contains($0) }
                }
                .sorted { ($0["created"] as? Double ?? 0) > ($1["created"] as? Double ?? 0) }
                .compactMap { $0["id"] as? String }
        }
    }

    // MARK: Helpers

    /// `output_config.effort` exists on Claude 4.6+ (and Opus 4.5); older
    /// models such as Haiku 4.5 reject it.
    static func anthropicSupportsEffort(_ model: String) -> Bool {
        let ids = ["claude-fable", "claude-mythos", "claude-opus-5", "claude-sonnet-5", "claude-haiku-5",
                   "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5", "claude-sonnet-4-6"]
        return ids.contains { model.hasPrefix($0) }
    }

    /// Server-side refusal fallback (the "default" routing form) on the models
    /// that have one. Haiku models have no server-side fallback.
    static func anthropicSupportsFallback(_ model: String) -> Bool {
        ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"].contains(model)
    }

    static func errorMessage(from body: String) -> String {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let err = json["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
        return ""
    }
}
