//
//  GoogleHealth.swift
//  OutPerform
//
//  Google Health backend for the **Google Health API** (the platform that
//  replaces the legacy Fitbit Web API; service host health.googleapis.com).
//  Auth is Google OAuth 2.0 (PKCE via ASWebAuthenticationSession); data is read
//  from the v4 dataPoints REST endpoints.
//
//  SETUP: in Google Cloud Console create an OAuth 2.0 **iOS** client, enable the
//  Google Health API, then paste the client id below. The redirect URL scheme
//  `com.outperform.app` is already registered in Info.plist.
//

import Foundation
import CryptoKit
import AuthenticationServices
import UIKit

enum GoogleHealthConfig {
    /// Compile-time default. Can be overridden at runtime from the in-app
    /// "Connect Google Health" screen (stored in UserDefaults) so users don't
    /// have to edit code and rebuild.
    static let defaultClientID = "REDACTED_GOOGLE_OAUTH_CLIENT_ID"
    private static let clientIDKey = "googleClientID"

    static var clientID: String {
        let stored = UserDefaults.standard.string(forKey: clientIDKey) ?? ""
        return stored.isEmpty ? defaultClientID : stored
    }
    static func setClientID(_ id: String) {
        UserDefaults.standard.set(id.trimmingCharacters(in: .whitespacesAndNewlines), forKey: clientIDKey)
    }

    /// Google iOS OAuth clients redirect to the *reversed* client id scheme.
    /// ASWebAuthenticationSession intercepts it, so no Info.plist change needed.
    static var redirectScheme: String {
        let id = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps.\(id)"
    }
    static var redirectURI: String { "\(redirectScheme):/oauth2redirect" }
    /// Google Health API scopes (https://www.googleapis.com/auth/googlehealth.*).
    static let scopes = [
        "https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly",
        "https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly",
        "https://www.googleapis.com/auth/googlehealth.sleep.readonly",
        "https://www.googleapis.com/auth/googlehealth.profile.readonly"
    ]
    static var isConfigured: Bool {
        !clientID.hasPrefix("YOUR_") && clientID.contains("apps.googleusercontent.com")
    }
}

// MARK: - OAuth

@MainActor
final class GoogleAuthManager: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GoogleAuthManager()

    private var codeVerifier: String?
    private var authSession: ASWebAuthenticationSession?

    /// In-memory cached access token + its expiry, so we don't hit Google's OAuth
    /// server on every API request (that turned a sync into minutes of serial
    /// token refreshes). Access tokens last ~1h; we refresh only when near expiry.
    private var cachedToken: (value: String, expiry: Date)?
    /// The single in-flight refresh, so concurrent callers share one network call
    /// instead of each kicking off their own.
    private var refreshTask: Task<String, Error>?

    var isSignedIn: Bool { Keychain.get("access_token") != nil }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Front-most window for the auth sheet (a sign-in always has a foreground scene).
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow)
            ?? windows.first
            ?? UIWindow(windowScene: scenes.first!)   // a sign-in always has a foreground scene
    }

    func signIn() async throws {
        guard GoogleHealthConfig.isConfigured else {
            throw HealthDataError.network("Google Health isn't set up yet. Add your OAuth client ID in GoogleHealthConfig.swift (see README), then rebuild.")
        }

        let verifier = Self.randomURLSafe(length: 64)
        codeVerifier = verifier
        let challenge = Self.codeChallenge(for: verifier)

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: GoogleHealthConfig.clientID),
            .init(name: "redirect_uri", value: GoogleHealthConfig.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: GoogleHealthConfig.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent")
        ]

        let callbackScheme = GoogleHealthConfig.redirectScheme
        let url: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: comps.url!, callbackURLScheme: callbackScheme) { url, error in
                if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: error ?? HealthDataError.signInRequired) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.authSession = session   // retain while presenting
            session.start()
        }

        guard let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw HealthDataError.signInRequired
        }
        try await exchangeCode(code, verifier: verifier)
    }

    func signOut() {
        Keychain.delete("access_token")
        Keychain.delete("refresh_token")
        cachedToken = nil
        refreshTask = nil
    }

    private func exchangeCode(_ code: String, verifier: String) async throws {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "client_id": GoogleHealthConfig.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": GoogleHealthConfig.redirectURI
        ]
        req.httpBody = Self.formEncode(body)
        let (data, _) = try await URLSession.shared.data(for: req)
        try store(tokenResponse: data)
    }

    /// Returns a valid access token, reusing the cached one until it's about to
    /// expire. Only refreshes over the network when needed, and coalesces
    /// concurrent callers onto a single refresh.
    func validAccessToken() async throws -> String {
        // Fast path: a cached token with comfortable headroom.
        if let cached = cachedToken, cached.expiry > Date().addingTimeInterval(120) {
            return cached.value
        }
        // Coalesce concurrent refreshes.
        if let inFlight = refreshTask {
            return try await inFlight.value
        }
        let task = Task<String, Error> { [weak self] in
            defer { self?.refreshTask = nil }
            return try await self?.performRefresh() ?? { throw HealthDataError.signInRequired }()
        }
        refreshTask = task
        return try await task.value
    }

    private func performRefresh() async throws -> String {
        guard let refresh = Keychain.get("refresh_token") else {
            if let access = Keychain.get("access_token") { return access }
            throw HealthDataError.signInRequired
        }
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "client_id": GoogleHealthConfig.clientID,
            "refresh_token": refresh,
            "grant_type": "refresh_token"
        ]
        req.httpBody = Self.formEncode(body)
        let (data, _) = try await URLSession.shared.data(for: req)
        try store(tokenResponse: data, keepRefresh: refresh)
        guard let token = Keychain.get("access_token") else { throw HealthDataError.signInRequired }
        // Cache with the server-provided lifetime (default 1h, minus a safety margin).
        let lifetime = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?
            .flatMap { ($0["expires_in"] as? Double) } ?? 3600
        cachedToken = (token, Date().addingTimeInterval(max(60, lifetime)))
        return token
    }

    private func store(tokenResponse data: Data, keepRefresh: String? = nil) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HealthDataError.network("Bad token response")
        }
        if let access = json["access_token"] as? String { Keychain.set(access, for: "access_token") }
        if let refresh = json["refresh_token"] as? String { Keychain.set(refresh, for: "refresh_token") }
        else if let keep = keepRefresh { Keychain.set(keep, for: "refresh_token") }
        if json["access_token"] == nil {
            throw HealthDataError.network((json["error_description"] as? String) ?? "Google sign-in failed")
        }
    }

    // PKCE helpers
    private static func randomURLSafe(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return Data(bytes).base64URLEncoded()
    }
    private static func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncoded()
    }
    private static func formEncode(_ dict: [String: String]) -> Data {
        Data(dict.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $1)" }
            .joined(separator: "&").utf8)
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}


// MARK: - Provider (Google Health API — health.googleapis.com/v4)

final class GoogleHealthProvider: HealthDataProvider {
    let sourceType: DataSourceType = .googleHealth

    private let base = "https://health.googleapis.com/v4/users/me"

    func isAvailable() -> Bool { GoogleHealthConfig.isConfigured }

    func requestAuthorization() async throws {
        try await GoogleAuthManager.shared.signIn()
    }

    private func token() async throws -> String {
        try await GoogleAuthManager.shared.validAccessToken()
    }

    // MARK: Generic dataPoints reader

    /// dataType in the *endpoint path* is kebab-case (`heart-rate`); in the
    /// *filter* it must be snake_case (`heart_rate`). The value lives under a
    /// camelCase field (`heartRate`).
    static func snakeCase(_ kebab: String) -> String { kebab.replacingOccurrences(of: "-", with: "_") }
    static func camelCase(_ kebab: String) -> String {
        let parts = kebab.split(separator: "-").map(String.init)
        guard let first = parts.first else { return kebab }
        return first + parts.dropFirst().map { $0.capitalized }.joined()
    }

    /// A data type's record kind decides the filter member + time format:
    ///  - sample  → `{type}.sample_time.physical_time` (RFC3339 Z)
    ///  - session → `{type}.interval.start_time`        (RFC3339 Z)
    ///  - daily   → `{type}.interval.civil_start_time`  (civil date, yyyy-MM-dd)
    enum RecordKind { case sample, session, daily }

    static func recordKind(_ dataType: String) -> RecordKind {
        switch dataType {
        case "heart-rate", "oxygen-saturation", "vo2-max", "run-vo2-max",
             "respiratory-rate-sleep-summary", "weight", "body-fat":
            return .sample
        case "sleep", "exercise":
            return .session
        default:
            return dataType.hasPrefix("daily-") ? .daily : .sample
        }
    }

    /// Time-range filter expression, per the data type's record kind.
    private func filterExpression(_ dataType: String, from: Date, to: Date) -> String {
        let type = Self.snakeCase(dataType)
        switch Self.recordKind(dataType) {
        case .sample:
            let f = "\(type).sample_time.physical_time"
            return "\(f) >= \"\(Self.filterTime.string(from: from))\" AND \(f) < \"\(Self.filterTime.string(from: to))\""
        case .session:
            let f = "\(type).interval.start_time"
            return "\(f) >= \"\(Self.filterTime.string(from: from))\" AND \(f) < \"\(Self.filterTime.string(from: to))\""
        case .daily:
            // Daily records carry a civil `date` (google.type.Date), filtered as yyyy-MM-dd.
            // Advance `to` by one day so today's records are inside the half-open [from, to+1)
            // window. Uses the device's local timezone so UTC+N users don't lose the current
            // local date (e.g. 3 PM Portugal = 2 PM UTC, still "today" locally).
            let f = "\(type).date"
            let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: to)!
            return "\(f) >= \"\(Self.localCivilDate.string(from: from))\" AND \(f) < \"\(Self.localCivilDate.string(from: nextDay))\""
        }
    }

    /// Raw dataPoints for a Google Health data type, following `nextPageToken`
    /// pagination. `filter` nil → no filter (list all; used as a fallback when a
    /// type's filter syntax is rejected, then we match client-side).
    private func rawDataPoints(_ dataType: String, filter: String?,
                               maxPoints: Int = 50_000) async throws -> [[String: Any]] {
        let token = try await token()
        var out: [[String: Any]] = []
        var pageToken: String?
        repeat {
            var comps = URLComponents(string: "\(base)/dataTypes/\(dataType)/dataPoints")!
            comps.queryItems = [.init(name: "pageSize", value: "1000")]
            if let filter { comps.queryItems?.append(.init(name: "filter", value: filter)) }
            if let pt = pageToken { comps.queryItems?.append(.init(name: "pageToken", value: pt)) }
            var req = URLRequest(url: comps.url!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 401 { throw HealthDataError.signInRequired }
                if http.statusCode == 403 { throw HealthDataError.network("Google Health: scope not granted for \(dataType).") }
                if http.statusCode >= 400 {
                    // A data type the account has no data/permission for — treat as empty.
                    break
                }
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
            if let points = json["dataPoints"] as? [[String: Any]] { out.append(contentsOf: points) }
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil && out.count < maxPoints
        return out
    }

    /// Convenience: build the per-kind filter and fetch.
    private func rawDataPoints(_ dataType: String, from: Date, to: Date) async throws -> [[String: Any]] {
        try await rawDataPoints(dataType, filter: filterExpression(dataType, from: from, to: to))
    }

    /// Map dataPoints to numeric QuantitySamples. The metric lives under the
    /// camelCase data-type field (e.g. `heartRate.beatsPerMinute`); time is in a
    /// nested `interval`/`sampleTime`.
    private func samples(_ dataType: String, from: Date, to: Date,
                         transform: (Double) -> Double = { $0 }) async throws -> [QuantitySample] {
        let points = (try? await rawDataPoints(dataType, from: from, to: to)) ?? []
        let valueField = Self.camelCase(dataType)
        return points.compactMap { p in
            let valueObj = p[valueField] ?? p
            // Prefer the known metric field; otherwise the first number that
            // isn't part of a date/time/metadata sub-object.
            let value = Self.metricKey(dataType).flatMap { Self.findNumber(in: valueObj, key: $0) }
                ?? Self.firstNumberSkippingTime(valueObj)
            guard let start = Self.startTime(p), let value else { return nil }
            let end = Self.endTime(p) ?? start
            return QuantitySample(start: start, end: end, value: transform(value))
        }.sorted { $0.start < $1.start }
    }

    // MARK: HealthDataProvider conformance

    func heartRates(from: Date, to: Date) async throws -> [QuantitySample] {
        // Heart-rate is high-frequency (tens of thousands of samples/day). The
        // generic reader caps at a total point count, and Google returns newest
        // first — so a single ranged query would only ever return the most recent
        // 2-3 days and every older day would compute no strain. Fetch one calendar
        // day at a time so each day is independently paginated and the WHOLE range
        // is covered, then thin to ≤1 sample/30 s (plenty for TRIMP) to bound memory.
        var cal = Calendar.current
        cal.timeZone = .current
        // Build the list of day windows up front.
        var windows: [(Date, Date)] = []
        var dayStart = cal.startOfDay(for: from)
        while dayStart < to {
            let dayEnd = min(cal.date(byAdding: .day, value: 1, to: dayStart)!, to)
            windows.append((dayStart, dayEnd))
            dayStart = cal.date(byAdding: .day, value: 1, to: dayStart)!
        }
        // Fetch days concurrently (bounded) so a full backfill isn't serial.
        let maxConcurrent = 5
        var out: [QuantitySample] = []
        var index = 0
        while index < windows.count {
            let batch = windows[index..<min(index + maxConcurrent, windows.count)]
            try await withThrowingTaskGroup(of: [QuantitySample].self) { group in
                for (s, e) in batch {
                    group.addTask {
                        let day = (try? await self.samples("heart-rate", from: s, to: e)) ?? []
                        return Self.thin(day, minGap: 30)
                    }
                }
                for try await day in group { out.append(contentsOf: day) }
            }
            index += maxConcurrent
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Keep at most one sample per `minGap` seconds (input assumed sorted by start).
    private static func thin(_ samples: [QuantitySample], minGap: TimeInterval) -> [QuantitySample] {
        var kept: [QuantitySample] = []
        var lastKept: Date?
        for s in samples {
            if let last = lastKept, s.start.timeIntervalSince(last) < minGap { continue }
            kept.append(s); lastKept = s.start
        }
        return kept
    }

    /// Google reports an HRV summary (ms). The engine treats this as the HRV
    /// signal (SDNN-equivalent); beat-to-beat RR isn't exposed, so RMSSD/DFA are
    /// skipped and recovery uses this value.
    func hrvSDNN(from: Date, to: Date) async throws -> [QuantitySample] {
        try await samples("daily-heart-rate-variability", from: from, to: to)
    }

    func restingHeartRate(from: Date, to: Date) async throws -> [QuantitySample] {
        try await samples("daily-resting-heart-rate", from: from, to: to)
    }

    func respiratoryRate(from: Date, to: Date) async throws -> [QuantitySample] {
        try await samples("respiratory-rate-sleep-summary", from: from, to: to)
    }

    func oxygenSaturation(from: Date, to: Date) async throws -> [QuantitySample] {
        // Normalise a 0–1 fraction to a percentage, then drop physiologically
        // implausible readings (<70%) so noise doesn't trigger false hypoxia.
        let raw = try await samples("oxygen-saturation", from: from, to: to) { $0 <= 1.0 ? $0 * 100 : $0 }
        return raw.filter { $0.value >= 70 && $0.value <= 100 }
    }

    /// Sleeping skin-temperature derivation (a deviation in °C). The engine uses
    /// it as a deviation-from-baseline, which matches this data type.
    func wristTemperature(from: Date, to: Date) async throws -> [QuantitySample] {
        try await samples("daily-sleep-temperature-derivations", from: from, to: to)
    }

    func vo2Max(from: Date, to: Date) async throws -> [QuantitySample] {
        let general = try await samples("vo2-max", from: from, to: to)
        if !general.isEmpty { return general }
        return try await samples("run-vo2-max", from: from, to: to)
    }

    // Beat-to-beat RR isn't available; engine falls back to the HRV summary.
    func beatToBeatRR(from: Date, to: Date) async throws -> [QuantitySample] { [] }

    func sleepSegments(from: Date, to: Date) async throws -> [SleepSegment] {
        // Sleep is a session whose repeated `interval` field rejects the usual
        // filter (confirmed against the live API), so list with no filter and
        // match the window client-side via each session's interval.
        let all = (try? await rawDataPoints("sleep", filter: nil, maxPoints: 8000)) ?? []
        var points = all.filter { p in
            guard let (s, e) = Self.sleepInterval(p) else { return false }
            return s < to && e > from
        }

        // De-duplicate: the same night is synced from multiple platforms
        // (FITBIT + Health Sync's HEALTH_KIT copy). Overlapping sessions are the
        // same sleep — keep the single most-detailed one so totals don't double.
        points = Self.dedupSleepSessions(points)

        var segments: [SleepSegment] = []
        for p in points {
            let sleepObj = (p["sleep"] as? [String: Any]) ?? p

            // Best: explicit per-segment stages (startTime/endTime/type).
            if let stages = sleepObj["stages"] as? [[String: Any]], !stages.isEmpty {
                for st in stages {
                    guard let s = Self.parseDate(st["startTime"]),
                          let e = Self.parseDate(st["endTime"]) else { continue }
                    segments.append(SleepSegment(start: s, end: e, stage: Self.mapSleepStageType(st["type"] as? String)))
                }
            } else if let summary = Self.findArray(in: sleepObj, key: "stagesSummary"), !summary.isEmpty,
                      let (start, _) = Self.sleepInterval(p) {
                // Classic sleep: only per-stage minute totals → lay out sequentially.
                var cursor = start
                for entry in summary {
                    let minutes = (Self.findNumber(in: entry, key: "totalDurationMinutes")
                                   ?? Self.findNumber(in: entry, key: "minutes")
                                   ?? Self.durationMinutes(entry["totalDuration"])) ?? 0
                    guard minutes > 0 else { continue }
                    let next = cursor.addingTimeInterval(minutes * 60)
                    segments.append(SleepSegment(start: cursor, end: next,
                                                 stage: Self.mapSleepStageType(Self.firstString(in: entry["type"]))))
                    cursor = next
                }
            } else if let (s, e) = Self.sleepInterval(p) {
                segments.append(SleepSegment(start: s, end: e, stage: .asleepUnspecified))
            }
        }
        return segments.sorted { $0.start < $1.start }
    }

    /// Collapse duplicate/overlapping sleep sessions (same night synced from
    /// multiple sources) to one per cluster — the one with the most stage detail.
    private static func dedupSleepSessions(_ points: [[String: Any]]) -> [[String: Any]] {
        func stageCount(_ p: [String: Any]) -> Int {
            ((p["sleep"] as? [String: Any])?["stages"] as? [[String: Any]])?.count ?? 0
        }
        // Sort by start; on ties, more stages first.
        let sorted = points.sorted { a, b in
            let sa = sleepInterval(a)?.0 ?? .distantPast
            let sb = sleepInterval(b)?.0 ?? .distantPast
            if sa != sb { return sa < sb }
            return stageCount(a) > stageCount(b)
        }
        var kept: [[String: Any]] = []
        for p in sorted {
            guard let (s, e) = sleepInterval(p) else { continue }
            if let lastIdx = kept.indices.last, let (ls, le) = sleepInterval(kept[lastIdx]),
               ls < e && s < le {            // overlaps the last kept session
                if stageCount(p) > stageCount(kept[lastIdx]) { kept[lastIdx] = p }  // keep richer copy
            } else {
                kept.append(p)
            }
        }
        return kept
    }

    /// Session interval bounds from a sleep dataPoint (`sleep.interval`).
    private static func sleepInterval(_ p: [String: Any]) -> (Date, Date)? {
        let sleepObj = (p["sleep"] as? [String: Any]) ?? p
        guard let interval = sleepObj["interval"] as? [String: Any],
              let s = parseDate(interval["startTime"]) else { return nil }
        let e = parseDate(interval["endTime"]) ?? s
        return (s, e)
    }

    /// Google SleepStageType enum → our stage.
    static func mapSleepStageType(_ raw: String?) -> SleepStage {
        switch (raw ?? "").uppercased() {
        case let s where s.contains("DEEP"): return .deep
        case let s where s.contains("REM"): return .rem
        case let s where s.contains("LIGHT"): return .core
        case let s where s.contains("AWAKE") || s.contains("RESTLESS"): return .awake
        default: return .asleepUnspecified
        }
    }

    /// Parse a protobuf Duration string ("123.4s") into minutes.
    private static func durationMinutes(_ any: Any?) -> Double? {
        guard let s = any as? String, s.hasSuffix("s"), let secs = Double(s.dropLast()) else { return nil }
        return secs / 60
    }

    func workouts(from: Date, to: Date) async throws -> [WorkoutSession] {
        var points = (try? await rawDataPoints("exercise", from: from, to: to)) ?? []
        if points.isEmpty {
            let all = (try? await rawDataPoints("exercise", filter: nil, maxPoints: 4000)) ?? []
            points = all.filter { p in
                guard let s = Self.startTime(p) else { return false }
                let e = Self.endTime(p) ?? s
                return s < to && e > from
            }
        }
        var out: [WorkoutSession] = []
        for p in points {
            guard let start = Self.startTime(p), let end = Self.endTime(p) else { continue }
            let activity = Self.workoutActivity(in: p)
            // Don't re-fetch heart-rate per workout — that's a serial round-trip per
            // session on top of the day's HR we already pull. The engine computes
            // workout load by slicing the day's heart-rate to the workout window.
            out.append(WorkoutSession(start: start, end: end, activity: activity, heartRates: []))
        }
        return out
    }

    // MARK: Diagnostics

    /// Hits the profile endpoint and several dataPoints endpoints, returning the
    /// raw HTTP status + response body for each so connection/endpoint/scope
    /// problems are visible instead of silently becoming "no data".
    func diagnostics(from: Date, to: Date) async -> String {
        var report = "Google Health diagnostics — \(Date().formatted(date: .abbreviated, time: .shortened))\n"
        func line(_ s: String) { report += s + "\n" }

        let token: String
        do { token = try await self.token() }
        catch { return report + "\n❌ Could not get an access token: \(error.localizedDescription)\nYou may need to sign in again." }
        line("✅ Access token OK (len \(token.count))")
        line("Window: \(Self.rfc3339.string(from: from)) → \(Self.rfc3339.string(from: to))")

        func dpURL(_ type: String) -> URL {
            var c = URLComponents(string: "\(base)/dataTypes/\(type)/dataPoints")!
            c.queryItems = [
                .init(name: "filter", value: filterExpression(type, from: from, to: to)),
                .init(name: "pageSize", value: "5")
            ]
            return c.url!
        }

        let tests: [(String, URL)] = [
            ("profile", URL(string: "\(base)/profile")!),
            ("daily-heart-rate-variability", dpURL("daily-heart-rate-variability")),
            ("daily-sleep-temperature-derivations", dpURL("daily-sleep-temperature-derivations")),
            ("respiratory-rate-sleep-summary", dpURL("respiratory-rate-sleep-summary"))
        ]
        for (name, url) in tests {
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            line("\n── \(name) ──")
            line(url.absoluteString)
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                let body = String(data: data.prefix(700), encoding: .utf8) ?? "<\(data.count) bytes>"
                line("HTTP \(code)")
                line(body)
            } catch {
                line("request error: \(error.localizedDescription)")
            }
        }

        // Filter-member probes: try candidate filters for the still-failing
        // daily/session types and report just the status, so we can lock in the
        // member that returns 200.
        line("\n=== FILTER PROBES (status only) ===")
        let physFrom = Self.filterTime.string(from: from), physTo = Self.filterTime.string(from: to)
        let civFrom = Self.civilDate.string(from: from), civTo = Self.civilDate.string(from: to)
        /// `filter` nil → no filter param at all.
        func probe(_ type: String, _ label: String, _ filter: String?, showBody: Bool = false) async {
            var c = URLComponents(string: "\(base)/dataTypes/\(type)/dataPoints")!
            c.queryItems = [.init(name: "pageSize", value: "2")]
            if let filter { c.queryItems?.append(.init(name: "filter", value: filter)) }
            var req = URLRequest(url: c.url!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            var status = "?"
            var note = ""
            if let (data, resp) = try? await URLSession.shared.data(for: req) {
                status = "\((resp as? HTTPURLResponse)?.statusCode ?? -1)"
                if let s = String(data: data.prefix(showBody ? 500 : 170), encoding: .utf8) {
                    if status != "200", let r = s.range(of: "\"message\":") {
                        note = "  " + s[r.lowerBound...].prefix(90)
                    } else if showBody {
                        note = "\n   " + s.replacingOccurrences(of: "\n", with: " ")
                    }
                }
            }
            line("[\(status)] \(label)\(note)")
        }
        for f in [
            ("date", "daily_resting_heart_rate.date >= \"\(civFrom)\" AND daily_resting_heart_rate.date < \"\(civTo)\"")
        ] { await probe("daily-resting-heart-rate", f.0, f.1) }
        // Sleep is a session; figure out the working query.
        await probe("sleep", "no-filter (list all)", nil, showBody: true)
        await probe("sleep", "create_time", "sleep.create_time >= \"\(physFrom)\" AND sleep.create_time < \"\(physTo)\"")
        await probe("sleep", "update_time", "sleep.update_time >= \"\(physFrom)\" AND sleep.update_time < \"\(physTo)\"")
        await probe("sleep", "interval.civil_start_time", "sleep.interval.civil_start_time >= \"\(civFrom)\" AND sleep.interval.civil_start_time < \"\(civTo)\"")
        return report
    }

    // MARK: Parsing helpers (resilient to the exact dataPoint schema)

    static let rfc3339: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let rfc3339NoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    /// Physical-time format inside the `filter` expression (RFC3339 Z).
    static let filterTime: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    /// Civil-date format (yyyy-MM-dd, UTC) for daily-record filters.
    static let civilDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    /// Civil-date format in the device's local timezone — used for the upper bound
    /// of daily-record filters so today's records aren't excluded for UTC+ users.
    static let localCivilDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func parseDate(_ any: Any?) -> Date? {
        if let s = any as? String {
            return rfc3339.date(from: s) ?? rfc3339NoFrac.date(from: s) ?? civilDate.date(from: s)
        }
        // Civil date / datetime object: { year, month, day, [hours, minutes] }.
        if let dict = any as? [String: Any],
           let y = firstNumber(in: dict["year"]),
           let m = firstNumber(in: dict["month"]),
           let d = firstNumber(in: dict["day"]) {
            var c = DateComponents()
            c.year = Int(y); c.month = Int(m); c.day = Int(d)
            c.hour = (firstNumber(in: dict["hours"]).map(Int.init)) ?? 0
            c.minute = (firstNumber(in: dict["minutes"]).map(Int.init)) ?? 0
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            return cal.date(from: c)
        }
        if let n = firstNumber(in: any) {
            if n > 1e15 { return Date(timeIntervalSince1970: n / 1e9) }   // nanos
            if n > 1e12 { return Date(timeIntervalSince1970: n / 1e3) }   // millis
            if n > 1e9 { return Date(timeIntervalSince1970: n) }          // seconds
        }
        return nil
    }

    /// Recursively find the first date under any key whose lowercased name
    /// contains one of `keys` (e.g. "starttime"). Times live in nested
    /// `interval`/`sampleTime` objects whose exact nesting varies by data type.
    private static func recursiveDate(_ any: Any?, keys: [String]) -> Date? {
        switch any {
        case let dict as [String: Any]:
            for (k, v) in dict where keys.contains(where: { k.lowercased().contains($0) }) {
                if let d = parseDate(v) { return d }
            }
            for (_, v) in dict { if let d = recursiveDate(v, keys: keys) { return d } }
            return nil
        case let arr as [Any]:
            for v in arr { if let d = recursiveDate(v, keys: keys) { return d } }
            return nil
        default: return nil
        }
    }

    private static func startTime(_ p: [String: Any]) -> Date? {
        recursiveDate(p, keys: ["starttime", "start_time"])
            ?? recursiveDate(p, keys: ["sampletime", "physicaltime", "time", "date"])
    }

    private static func endTime(_ p: [String: Any]) -> Date? {
        recursiveDate(p, keys: ["endtime", "end_time"])
    }

    /// Recursively find an array under a key matching `key` (case-insensitive).
    static func findArray(in any: Any?, key: String) -> [[String: Any]]? {
        switch any {
        case let dict as [String: Any]:
            for (k, v) in dict where k.lowercased() == key.lowercased() {
                if let arr = v as? [[String: Any]] { return arr }
            }
            for (_, v) in dict { if let a = findArray(in: v, key: key) { return a } }
            return nil
        case let arr as [Any]:
            for v in arr { if let a = findArray(in: v, key: key) { return a } }
            return nil
        default: return nil
        }
    }

    /// Exact metric value field per data type (verified from live responses).
    static func metricKey(_ dataType: String) -> String? {
        switch dataType {
        case "heart-rate", "daily-resting-heart-rate": return "beatsPerMinute"
        case "daily-heart-rate-variability": return "averageHeartRateVariabilityMilliseconds"
        case "oxygen-saturation", "daily-oxygen-saturation": return "percentage"
        case "vo2-max", "run-vo2-max": return "vo2Max"
        case "respiratory-rate-sleep-summary": return "breathsPerMinute"
        case "daily-sleep-temperature-derivations": return "nightlyTemperatureCelsius"
        default: return nil
        }
    }

    /// Recursively find the first number under an exact (case-insensitive) key.
    static func findNumber(in any: Any?, key: String) -> Double? {
        switch any {
        case let dict as [String: Any]:
            for (k, v) in dict where k.caseInsensitiveCompare(key) == .orderedSame {
                if let n = firstNumber(in: v) { return n }
            }
            for (_, v) in dict { if let n = findNumber(in: v, key: key) { return n } }
            return nil
        case let arr as [Any]:
            for v in arr { if let n = findNumber(in: v, key: key) { return n } }
            return nil
        default: return nil
        }
    }

    /// First number, skipping date/time/metadata sub-objects so we never grab a
    /// year or an offset by mistake.
    static func firstNumberSkippingTime(_ any: Any?) -> Double? {
        switch any {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        case let dict as [String: Any]:
            let skip = ["date", "time", "interval", "offset", "metadata", "civil", "source", "name"]
            for (k, v) in dict {
                let kl = k.lowercased()
                if skip.contains(where: { kl.contains($0) }) { continue }
                if let n = firstNumberSkippingTime(v) { return n }
            }
            return nil
        case let arr as [Any]:
            for v in arr { if let n = firstNumberSkippingTime(v) { return n } }
            return nil
        default: return nil
        }
    }

    /// Recursively find the first numeric value, preferring common field names.
    static func firstNumber(in any: Any?) -> Double? {
        switch any {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        case let dict as [String: Any]:
            let preferred = ["beatsPerMinute", "percentage", "vo2Max", "breathsPerMinute",
                             "value", "fpVal", "doubleValue", "quantity", "bpm",
                             "percent", "milliseconds", "millis", "ms", "celsius",
                             "minutes", "average", "avg", "mean", "count", "intVal"]
            for k in preferred { if let v = dict[k], let n = firstNumber(in: v) { return n } }
            for (_, v) in dict { if let n = firstNumber(in: v) { return n } }
            return nil
        case let arr as [Any]:
            for v in arr { if let n = firstNumber(in: v) { return n } }
            return nil
        default: return nil
        }
    }

    /// Recursively find the first string value (for stage / activity enums).
    private static func firstString(in any: Any?) -> String? {
        switch any {
        case let s as String: return s
        case let dict as [String: Any]:
            for (_, v) in dict { if let s = firstString(in: v) { return s } }
            return nil
        case let arr as [Any]:
            for v in arr { if let s = firstString(in: v) { return s } }
            return nil
        default: return nil
        }
    }

    private static func sleepStage(in p: [String: Any]) -> SleepStage {
        let s = (firstString(in: p["value"]) ?? "").lowercased()
        if s.contains("deep") { return .deep }
        if s.contains("rem") { return .rem }
        if s.contains("light") || s.contains("core") { return .core }
        if s.contains("wake") || s.contains("awake") { return .awake }
        if s.contains("restless") || s.contains("asleep") || s.contains("sleep") { return .asleepUnspecified }
        return .asleepUnspecified
    }

    private static func workoutActivity(in p: [String: Any]) -> WorkoutActivity {
        let s = (firstString(in: p["value"]) ?? "").lowercased()
        if s.contains("strength") || s.contains("weight") { return .weightlifting }
        if s.contains("hiit") || s.contains("interval") || s.contains("cross") { return .hiit }
        if s.contains("yoga") || s.contains("pilates") { return .yoga }
        if s.contains("run") { return .running }
        if s.contains("cycl") || s.contains("bik") { return .cycling }
        if s.contains("walk") || s.contains("hik") { return .walking }
        return .other
    }
}
