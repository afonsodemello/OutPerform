//
//  BandDataProvider.swift
//  OutPerform
//
//  The Bluetooth data source. Everything comes from what the band streamed
//  to this phone (`StreamStore`); nothing is fetched from any cloud.
//
//  Raw heart rate and heartbeats are turned into the same nightly/daily
//  inputs the other providers deliver:
//    heart rate  → 1-minute means
//    sleep       → HRSleepAnalyzer (HR-drop detection + 4-stage hypnogram)
//    resting HR  → lowest 5-minute bin mean while asleep
//    HRV         → mean of 5-minute RMSSD windows while asleep (+ SDNN)
//    breathing   → RSA peaks in the heartbeat intervals while asleep
//    workouts    → HRWorkoutDetector, with Keytel calories
//  Blood oxygen, skin temperature and VO2 max are not part of the open
//  heart-rate profile, so those stay empty (VO2 max is estimated later from
//  HRmax / resting HR by the engine).
//

import Foundation

final class BandDataProvider: HealthDataProvider {
    let sourceType: DataSourceType = .bluetooth
    private let analysis = BandAnalysis.shared

    func isAvailable() -> Bool { true }

    func requestAuthorization() async throws {
        // Creating the central manager is what triggers the Bluetooth prompt.
        await BandManager.shared.startWhenReady()
    }

    private var profile: BodyProfile {
        let s = AppSettings.shared
        return BodyProfile(age: s.age, sex: s.biologicalSex, weightKg: s.weightKg, heightCm: s.heightCm)
    }

    func heartRates(from: Date, to: Date) async throws -> [QuantitySample] {
        await analysis.minuteHR(from: from, to: to)
    }

    /// One hour of clean asleep beats from the middle of each night: enough
    /// for DFA-α1 without handing the engine a whole night of beats.
    func beatToBeatRR(from: Date, to: Date) async throws -> [QuantitySample] {
        await analysis.nightBeats(from: from, to: to)
    }

    func nightlyRMSSD(from: Date, to: Date) async throws -> [QuantitySample] {
        await analysis.nights(from: from, to: to).compactMap { n in
            n.rmssd.map { QuantitySample(date: n.end, value: $0) }
        }
    }

    func hrvSDNN(from: Date, to: Date) async throws -> [QuantitySample] {
        await analysis.nights(from: from, to: to).compactMap { n in
            n.sdnn.map { QuantitySample(date: n.end, value: $0) }
        }
    }

    func restingHeartRate(from: Date, to: Date) async throws -> [QuantitySample] {
        await analysis.nights(from: from, to: to).compactMap { n in
            n.restingHR.map { QuantitySample(date: n.end, value: $0) }
        }
    }

    func respiratoryRate(from: Date, to: Date) async throws -> [QuantitySample] {
        await analysis.nights(from: from, to: to).compactMap { n in
            n.respiratoryRate.map { QuantitySample(date: n.end, value: $0) }
        }
    }

    func oxygenSaturation(from: Date, to: Date) async throws -> [QuantitySample] { [] }
    func wristTemperature(from: Date, to: Date) async throws -> [QuantitySample] { [] }
    func vo2Max(from: Date, to: Date) async throws -> [QuantitySample] { [] }

    func sleepSegments(from: Date, to: Date) async throws -> [SleepSegment] {
        await analysis.nights(from: from, to: to).flatMap(\.segments)
    }

    func workouts(from: Date, to: Date) async throws -> [WorkoutSession] {
        await analysis.workouts(from: from, to: to, profile: profile).map {
            WorkoutSession(start: $0.start, end: $0.end, activity: .other,
                           heartRates: $0.heartRates, activeEnergyKcal: $0.kcal)
        }
    }
}

/// Runs the stream analysis off the main thread and caches finished nights,
/// so a 15-minute re-score only re-analyses the night still in progress.
actor BandAnalysis {
    static let shared = BandAnalysis()

    private let store = StreamStore.shared
    private var nightCache: [Date: (session: BandSleepSession?, final: Bool)] = [:]

    /// Same window the engine uses: previous 18:00 → 14:00.
    private func nightWindow(for day: Date) -> (Date, Date) {
        let cal = Calendar.current
        let sod = cal.startOfDay(for: day)
        return (cal.date(byAdding: .hour, value: -6, to: sod)!, cal.date(byAdding: .hour, value: 14, to: sod)!)
    }

    func minuteHR(from: Date, to: Date) async -> [QuantitySample] {
        let points = await store.heartRate(from: from, to: to)
        return Self.minuteMeans(points)
    }

    static func minuteMeans(_ points: [HRPoint]) -> [QuantitySample] {
        var out: [QuantitySample] = []
        var minute = -1, sum = 0.0, n = 0
        func emit() {
            guard n > 0 else { return }
            let s = Date(timeIntervalSince1970: Double(minute) * 60)
            out.append(QuantitySample(start: s, end: s.addingTimeInterval(60), value: sum / Double(n)))
        }
        for p in points {
            let m = Int(p.t / 60)
            if m != minute { emit(); minute = m; sum = 0; n = 0 }
            sum += p.bpm; n += 1
        }
        emit()
        return out
    }

    /// Analysed nights whose wake time falls in `[from, to]`, oldest first.
    func nights(from: Date, to: Date) async -> [BandSleepSession] {
        let cal = Calendar.current
        let now = Date()
        var out: [BandSleepSession] = []
        var day = cal.startOfDay(for: from)
        let lastDay = cal.startOfDay(for: min(to, now).addingTimeInterval(10 * 3600))
        while day <= lastDay {
            if let s = await night(for: day, now: now), s.end >= from, s.end <= to { out.append(s) }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return out
    }

    private func night(for day: Date, now: Date) async -> BandSleepSession? {
        if let cached = nightCache[day], cached.final { return cached.session }
        let (w0, wFull) = nightWindow(for: day)
        guard w0 < now else { return nil }
        let w1 = min(now, wFull)
        let hr = await store.heartRate(from: w0, to: w1)
        let beats = hr.isEmpty ? [] : await store.beats(from: w0, to: w1)
        let reference = await wakingReference(before: w0)
        let session = HRSleepAnalyzer.analyzeNight(hr: hr, beats: beats, windowStart: w0, windowEnd: w1,
                                                   wakingReferenceHR: reference)
        // A night is final once its window closed (with a margin for late writes).
        nightCache[day] = (session, now > wFull.addingTimeInterval(1800))
        return session
    }

    /// Median daytime HR (09:00–20:00 the day before the night) — what
    /// "awake" looks like for you, so the sleep band is personal.
    private func wakingReference(before nightStart: Date) async -> Double? {
        let cal = Calendar.current
        let sod = cal.startOfDay(for: nightStart)
        let a = cal.date(byAdding: .hour, value: 9, to: sod)!, b = cal.date(byAdding: .hour, value: 20, to: sod)!
        let minutes = Self.minuteMeans(await store.heartRate(from: a, to: b))
        return minutes.count >= 60 ? Stats.median(minutes.map(\.value)) : nil
    }

    func nightBeats(from: Date, to: Date) async -> [QuantitySample] {
        var out: [QuantitySample] = []
        for n in await nights(from: from, to: to) where n.hasBeatData {
            let mid = n.start.addingTimeInterval(n.end.timeIntervalSince(n.start) / 2)
            let a = max(n.start, mid.addingTimeInterval(-1800)), b = min(n.end, mid.addingTimeInterval(1800))
            let clean = BeatHRV.clean(await store.beats(from: a, to: b))
            out.append(contentsOf: clean.map { QuantitySample(date: Date(timeIntervalSince1970: $0.t), value: $0.rr) })
        }
        return out
    }

    func workouts(from: Date, to: Date, profile: BodyProfile) async -> [DetectedBout] {
        let minutes = await minuteHR(from: from, to: to)
        guard !minutes.isEmpty else { return [] }
        let nights = await nights(from: from, to: to.addingTimeInterval(14 * 3600))
        let sleep = nights.map { DateInterval(start: $0.start, end: $0.end) }
        let hrMax = EffortScorer.hrMax(age: profile.age, observed: minutes.map(\.value))
        let cal = Calendar.current
        let byDay = Dictionary(grouping: minutes) { cal.startOfDay(for: $0.start) }
        var out: [DetectedBout] = []
        for (day, dayMinutes) in byDay {
            // Resting HR: that morning's night, else the day's 10th percentile.
            let rhr = nights.first { cal.isDate($0.end, inSameDayAs: day) }?.restingHR
                ?? Stats.percentile(dayMinutes.map(\.value), 0.10)
            out += HRWorkoutDetector.detect(minuteHR: dayMinutes, restingHR: rhr, hrMax: hrMax,
                                            profile: profile, excluding: sleep)
        }
        return out.sorted { $0.start < $1.start }
    }

    func clearCache() { nightCache.removeAll() }
}
