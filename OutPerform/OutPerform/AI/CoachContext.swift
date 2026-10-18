//
//  CoachContext.swift
//  OutPerform
//
//  What the AI coach is told. The system prompt sets the coach's role; the
//  health summary (only with your consent) is a compact text table of your
//  computed daily scores, never raw heart-rate streams, heartbeats, GPS
//  routes or device identifiers.
//

import Foundation

enum CoachContext {
    static let systemPrompt = """
    You are OutPerform's coach: a knowledgeable, encouraging sports-science and sleep coach inside a \
    private recovery app. The user wears a heart-rate band and/or uses Apple Health / Google Health; \
    the app computes their scores on-device.

    How the app's numbers work:
    - Recovery (0–100%): HRV-led readiness vs. the user's own baseline. Green ≥ 67, yellow 34–66, red < 34.
    - Day strain (0–21, logarithmic): cardiovascular load from heart rate. < 10 light, 10–14 moderate, \
    14–18 high, ≥ 18 all-out.
    - Sleep performance (0–100): sleep vs. need, efficiency, deep + REM share, consistency.
    - Sleep need/debt in minutes; ACWR (acute:chronic load) 0.8–1.3 is the sweet spot, > 1.5 is risky.
    - HRV is RMSSD or SDNN in ms (higher is generally better vs. the person's own baseline); \
    resting HR in bpm (lower vs. baseline is generally better).

    How to answer:
    - Be specific and practical. Ground advice in the user's actual numbers when they're provided, \
    and say which numbers you're using. Compare against their own recent days rather than population norms.
    - Keep answers short and skimmable: a direct answer first, then up to 3–5 bullet points. \
    Use the user's units. No long preambles.
    - If data is missing or the user hasn't shared it, say so briefly and give general guidance.
    - You are not a doctor. Don't diagnose. For chest pain, fainting, very abnormal readings, \
    or symptoms that worry the user, tell them to seek medical care.
    - Scores are estimates from a consumer wearable, not clinical measurements.
    """

    static let briefRequest = """
    Write my brief for today in under 120 words: one line on how recovered I am and why, \
    a recommended strain target or type of training, one sleep recommendation for tonight, \
    and anything unusual in my data worth watching. Use short bullets.
    """

    /// Compact summary of recent data for the model. Called on the main actor.
    @MainActor
    static func healthSummary(records: [DailyRecord], workouts: [ExerciseSession],
                              includeWorkouts: Bool, illness: IllnessSignal?) -> String {
        let settings = AppSettings.shared
        let zones = ZoneSettings.shared
        let day = DateFormatter(); day.dateFormat = "EEE d MMM"
        let time = DateFormatter(); time.timeStyle = .short

        func f(_ v: Double?, _ digits: Int = 0, _ unit: String = "") -> String {
            guard let v else { return "–" }
            return String(format: "%.\(digits)f", v) + unit
        }
        func hm(_ min: Double?) -> String {
            guard let m = min else { return "–" }
            return "\(Int(m) / 60)h\(String(format: "%02d", Int(m) % 60))"
        }

        var out: [String] = []
        out.append("Now: \(Date().formatted(date: .complete, time: .shortened)).")
        out.append("Profile: age \(settings.age), \(settings.biologicalSex.displayName.lowercased()), "
                   + "\(Int(settings.weightKg)) kg, \(Int(settings.heightCm)) cm. "
                   + "Max HR \(zones.maxHR) bpm. Zones (lower bounds) Z1–Z5: \(zones.lowerBounds.map(String.init).joined(separator: "/")) bpm. "
                   + "Desired wake \(String(format: "%02d:%02d", settings.wakeMinuteOfDay / 60, settings.wakeMinuteOfDay % 60)).")

        let recent = records.sorted { $0.date > $1.date }.prefix(14)
        if let r = recent.first(where: { $0.recovery != nil || $0.dayStrain != nil || $0.totalSleepMin != nil }) {
            var lines = ["Latest day with data (\(day.string(from: r.date))):"]
            lines.append("- Readiness \(f(r.readiness)), recovery \(f(r.recovery, 0, "%")), sleep performance \(f(r.sleepPerformance, 0, "%")), stress \(f(r.stress))")
            lines.append("- HRV \(f(r.hrv, 0, " ms")), resting HR \(f(r.restingHR, 0, " bpm")), breathing \(f(r.respiratoryRate, 1, "/min")), SpO2 \(f(r.spo2Avg, 1, "%")), skin temp \(f(r.skinTempC, 2, " °C"))")
            lines.append("- Sleep \(hm(r.totalSleepMin)) of \(hm(r.timeInBedMin)) in bed, deep \(hm(r.deepMin)), REM \(hm(r.remMin)), efficiency \(f(r.sleepEfficiency, 0, "%")), wake-ups \(r.wakeEvents.map(String.init) ?? "–")"
                         + (r.sleepOnset.map { ", asleep \(time.string(from: $0))" } ?? "")
                         + (r.sleepWake.map { ", woke \(time.string(from: $0))" } ?? ""))
            lines.append("- Day strain \(f(r.dayStrain, 1))/21, activity strain \(f(r.activityStrain, 1)), ACWR \(f(r.acwr, 2)), monotony \(f(r.monotony, 2)), VO2max \(f(r.vo2Max, 1))")
            lines.append("- Sleep need tonight \(hm(r.sleepNeedMin)), sleep debt \(hm(r.sleepDebtMin))")
            out.append(lines.joined(separator: "\n"))
        }

        if recent.count > 1 {
            var rows = ["Last \(recent.count) days (newest first) — date | recovery% | strain | sleep | HRV ms | RHR | sleep perf%:"]
            for r in recent {
                rows.append("\(day.string(from: r.date)) | \(f(r.recovery)) | \(f(r.dayStrain, 1)) | \(hm(r.totalSleepMin)) | \(f(r.hrv)) | \(f(r.restingHR)) | \(f(r.sleepPerformance))")
            }
            out.append(rows.joined(separator: "\n"))
        }

        if includeWorkouts {
            let weekAgo = Date().addingTimeInterval(-7 * 86_400)
            let recentWorkouts = workouts.filter { $0.start >= weekAgo }
            if !recentWorkouts.isEmpty {
                var rows = ["Recorded workouts, last 7 days:"]
                for w in recentWorkouts {
                    var parts = ["\(day.string(from: w.start)) \(w.activity.displayName)", WorkoutFormat.duration(w.activeSeconds)]
                    if let d = w.distanceMeters { parts.append(WorkoutFormat.distance(d)) }
                    if let a = w.avgHR { parts.append("avg HR \(a)") }
                    if let m = w.maxHR { parts.append("max \(m)") }
                    let z45 = w.zoneSeconds.count > 5 ? (w.zoneSeconds[4] + w.zoneSeconds[5]) / 60 : 0
                    if z45 > 0 { parts.append("\(Int(z45)) min in Z4–5") }
                    if let k = w.kcal { parts.append("\(Int(k)) kcal") }
                    rows.append("- " + parts.joined(separator: ", "))
                }
                out.append(rows.joined(separator: "\n"))
            }
        }

        if let illness { out.append("Early-warning flag: \(illness.message)") }

        if recent.isEmpty { out.append("No scored days yet (the user is new or hasn't synced).") }
        return out.joined(separator: "\n\n")
    }
}
