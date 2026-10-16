//
//  SourceMerger.swift
//  OutPerform
//
//  Rules for blending the same biometrics from several sources without
//  double counting. Pure functions over value types, so they can be tested
//  in isolation.
//
//  The idea: for every slice of time, take the data from the best source that
//  has it. Whichever source synced first fills the slice; once a better
//  source catches up, it takes over on the next sync.
//
//   • Heart rate: per minute, highest-priority
//     source that has a sample in that minute. Gaps in one source are filled
//     by the next.
//   • Beat-to-beat intervals: one source per night (HRV must never span a
//     seam between two devices).
//   • Daily / nightly values (HRV, resting HR, breathing, SpO2, temp, VO2):
//     per calendar day, all values from the highest-priority source that has
//     one that day. Never averaged across sources (they measure differently).
//   • Sleep: per night, one source's whole hypnogram, never a mix (mixing
//     would double-count time in bed). A source with real stages (deep / REM)
//     beats one with only "asleep".
//   • Workouts: union, with overlapping sessions (≥ 50% of the shorter one)
//     treated as the same workout; the higher-priority copy wins and borrows
//     heart rate / calories from the other if it has none.
//

import Foundation

nonisolated public enum SourceKind: String, CaseIterable, Codable, Sendable, Hashable {
    case band, appleHealth, google

    public var displayName: String {
        switch self {
        case .band:        return "Bluetooth band"
        case .appleHealth: return "Apple Health"
        case .google:      return "Google Health"
        }
    }

    public var systemImage: String {
        switch self {
        case .band:        return "dot.radiowaves.left.and.right"
        case .appleHealth: return "heart.fill"
        case .google:      return "g.circle.fill"
        }
    }
}

nonisolated public enum SourceMerger {
    /// Direct beat-level measurements first.
    public static let cardiacPriority: [SourceKind] = [.band, .appleHealth, .google]
    /// Validated wearable staging first (Apple Watch), then the band's own.
    public static let sleepPriority: [SourceKind] = [.appleHealth, .band, .google]
    /// Sensors the band doesn't have (SpO2, skin temp, VO2 max).
    public static let vitalsPriority: [SourceKind] = [.appleHealth, .google, .band]

    public typealias Inputs<T> = [SourceKind: [T]]

    // MARK: Per-minute series

    public static func mergeSeries(_ inputs: Inputs<QuantitySample>,
                                   priority: [SourceKind] = cardiacPriority) -> [QuantitySample] {
        var covered = Set<Int>()
        var out: [QuantitySample] = []
        for kind in priority {
            guard let samples = inputs[kind], !samples.isEmpty else { continue }
            var mine = Set<Int>()
            for s in samples {
                let minute = Int(floor(s.start.timeIntervalSince1970 / 60))
                guard !covered.contains(minute) else { continue }
                out.append(s)
                mine.insert(minute)
            }
            covered.formUnion(mine)
        }
        return out.sorted { $0.start < $1.start }
    }

    // MARK: Per-day values

    public static func mergeDaily(_ inputs: Inputs<QuantitySample>, priority: [SourceKind],
                                  calendar: Calendar = .current) -> [QuantitySample] {
        var claimed = Set<Date>()
        var out: [QuantitySample] = []
        for kind in priority {
            guard let samples = inputs[kind], !samples.isEmpty else { continue }
            let byDay = Dictionary(grouping: samples) { calendar.startOfDay(for: $0.start) }
            for (day, daySamples) in byDay where !claimed.contains(day) {
                out.append(contentsOf: daySamples)
                claimed.insert(day)
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Beat-to-beat intervals: one source per night, so HRV is never computed
    /// across a seam between two devices' beats.
    public static func mergeBeatsByNight(_ inputs: Inputs<QuantitySample>,
                                         priority: [SourceKind] = cardiacPriority,
                                         calendar: Calendar = .current) -> [QuantitySample] {
        func key(_ q: QuantitySample) -> Date { calendar.startOfDay(for: q.start.addingTimeInterval(6 * 3600)) }
        var claimed = Set<Date>()
        var out: [QuantitySample] = []
        for kind in priority {
            guard let beats = inputs[kind], !beats.isEmpty else { continue }
            for (night, nightBeats) in Dictionary(grouping: beats, by: key) where !claimed.contains(night) {
                // A handful of beats isn't a night; let a fuller source have it.
                guard nightBeats.count >= 200 else { continue }
                out.append(contentsOf: nightBeats)
                claimed.insert(night)
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    // MARK: Gap finding

    /// The days (or nights, keyed by wake day) a fetch over `[from, to]`
    /// should contain. A night counts only once it's under way (after 04:00),
    /// so the coming night never looks "missing" in the evening.
    public static func expectedKeys(from: Date, to: Date, now: Date, nights: Bool,
                                    calendar: Calendar = .current) -> Set<Date> {
        let end = min(to, now)
        var keys = Set<Date>()
        if nights {
            var d = calendar.startOfDay(for: from.addingTimeInterval(6 * 3600))
            while d.addingTimeInterval(4 * 3600) <= end {
                keys.insert(d)
                d = calendar.date(byAdding: .day, value: 1, to: d)!
            }
        } else {
            var d = calendar.startOfDay(for: from)
            while d <= end {
                keys.insert(d)
                d = calendar.date(byAdding: .day, value: 1, to: d)!
            }
        }
        return keys
    }

    /// One contiguous window covering every missing key, clamped to the
    /// original request. nil when nothing is missing.
    public static func fetchSpan(for missing: Set<Date>, nights: Bool, clampFrom: Date, clampTo: Date,
                                 calendar: Calendar = .current) -> (Date, Date)? {
        guard let first = missing.min(), let last = missing.max() else { return nil }
        let start = nights ? first.addingTimeInterval(-6 * 3600) : first
        let end = nights ? last.addingTimeInterval(14 * 3600) : calendar.date(byAdding: .day, value: 1, to: last)!
        let a = max(start, clampFrom), b = min(end, clampTo)
        return a < b ? (a, b) : nil
    }

    // MARK: Sleep

    /// Night key: the calendar day you wake up on (an 18:00 → 14:00 window,
    /// matching the engine), from the segment's midpoint.
    public static func nightKey(_ s: SleepSegment, _ calendar: Calendar) -> Date {
        let mid = s.start.addingTimeInterval(s.end.timeIntervalSince(s.start) / 2)
        return calendar.startOfDay(for: mid.addingTimeInterval(6 * 3600))
    }

    public static func mergeSleep(_ inputs: Inputs<SleepSegment>,
                                  priority: [SourceKind] = sleepPriority,
                                  calendar: Calendar = .current) -> [SleepSegment] {
        var nights: [Date: [SourceKind: [SleepSegment]]] = [:]
        for (kind, segments) in inputs {
            for s in segments { nights[nightKey(s, calendar), default: [:]][kind, default: []].append(s) }
        }
        var out: [SleepSegment] = []
        for (_, bySource) in nights {
            func asleepMin(_ k: SourceKind) -> Double {
                bySource[k]?.filter(\.stage.isAsleep).reduce(0) { $0 + $1.durationMinutes } ?? 0
            }
            func staged(_ k: SourceKind) -> Bool {
                bySource[k]?.contains { $0.stage == .deep || $0.stage == .rem } ?? false
            }
            // Ignore a source that only caught a fragment (< 60 min asleep)
            // when another has the real night.
            let candidates = priority.filter { asleepMin($0) > 0 }
            let substantial = candidates.filter { asleepMin($0) >= 60 }
            let pool = substantial.isEmpty ? candidates : substantial
            let pick = pool.first(where: staged) ?? pool.first
            if let pick, let segs = bySource[pick] { out.append(contentsOf: segs) }
        }
        return out.sorted { $0.start < $1.start }
    }

    // MARK: Workouts

    public static func mergeWorkouts(_ inputs: Inputs<WorkoutSession>,
                                     priority: [SourceKind] = [.appleHealth, .google, .band]) -> [WorkoutSession] {
        var kept: [WorkoutSession] = []
        for kind in priority {
            for w in inputs[kind] ?? [] {
                if let i = kept.firstIndex(where: { sameWorkout($0, w) }) {
                    if kept[i].heartRates.isEmpty { kept[i].heartRates = w.heartRates }
                    if kept[i].activeEnergyKcal == nil { kept[i].activeEnergyKcal = w.activeEnergyKcal }
                    if kept[i].activity == .other, w.activity != .other { kept[i].activity = w.activity }
                } else {
                    kept.append(w)
                }
            }
        }
        return kept.sorted { $0.start < $1.start }
    }

    static func sameWorkout(_ a: WorkoutSession, _ b: WorkoutSession) -> Bool {
        let overlap = min(a.end, b.end).timeIntervalSince(max(a.start, b.start))
        let shorter = min(a.end.timeIntervalSince(a.start), b.end.timeIntervalSince(b.start))
        return overlap > 0 && shorter > 0 && overlap >= 0.5 * shorter
    }
}
