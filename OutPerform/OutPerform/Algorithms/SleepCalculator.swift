//
//  SleepCalculator.swift
//  OutPerform
//
//  Sleep metrics and the multi-factor sleep performance score
//

import Foundation

nonisolated public struct SleepMetrics: Sendable {
    public var totalSleepMin: Double
    public var timeInBedMin: Double
    public var remMin: Double
    public var deepMin: Double
    public var coreMin: Double
    public var awakeMin: Double
    public var efficiencyPct: Double      // total sleep / time in bed * 100
    public var restorativePct: Double     // (REM + deep) / total sleep * 100
    public var remPct: Double
    public var deepPct: Double
    public var wakeEvents: Int
    public var onset: Date?
    public var wake: Date?
}

nonisolated public struct SleepPerformance: Sendable {
    public var score: Double              // 0–100
    public var efficiencyScore: Double
    public var restorativeScore: Double
    public var needFulfillment: Double
    public var consistencyScore: Double
}

nonisolated public enum SleepCalculator {

    /// Tunable sleep-performance weights (Settings → Advanced).
    public struct Weights: Sendable {
        public var efficiency: Double = 0.30
        public var restorative: Double = 0.30
        public var fulfillment: Double = 0.25
        public var consistency: Double = 0.15
        public init(efficiency: Double = 0.30, restorative: Double = 0.30,
                    fulfillment: Double = 0.25, consistency: Double = 0.15) {
            self.efficiency = efficiency; self.restorative = restorative
            self.fulfillment = fulfillment; self.consistency = consistency
        }
        public static let `default` = Weights()
    }

    /// Aggregate raw sleep segments into nightly metrics.
    public static func metrics(from segments: [SleepSegment]) -> SleepMetrics {
        let asleep = segments.filter { $0.stage.isAsleep }
        let sorted = segments.sorted { $0.start < $1.start }

        let total = asleep.reduce(0) { $0 + $1.durationMinutes }
        let rem = segments.filter { $0.stage == .rem }.reduce(0) { $0 + $1.durationMinutes }
        let deep = segments.filter { $0.stage == .deep }.reduce(0) { $0 + $1.durationMinutes }
        let core = segments.filter { $0.stage == .core }.reduce(0) { $0 + $1.durationMinutes }
        let awake = segments.filter { $0.stage == .awake }.reduce(0) { $0 + $1.durationMinutes }

        let onset = sorted.first { $0.stage.isAsleep }?.start
        let wake = sorted.last { $0.stage.isAsleep }?.end

        // Time in bed: explicit inBed segments, else onset→wake span.
        let inBedSegments = segments.filter { $0.stage == .inBed }
        let timeInBed: Double
        if !inBedSegments.isEmpty {
            timeInBed = inBedSegments.reduce(0) { $0 + $1.durationMinutes }
        } else if let o = onset, let w = wake {
            timeInBed = max(total, w.timeIntervalSince(o) / 60)
        } else {
            timeInBed = total
        }

        let efficiency = timeInBed > 0 ? min(total / timeInBed * 100, 100) : 0
        let restorative = total > 0 ? (rem + deep) / total * 100 : 0

        // Wake events: awake segments > 5 min occurring after sleep onset.
        var wakeEvents = 0
        if let o = onset {
            wakeEvents = segments.filter { $0.stage == .awake && $0.start > o && $0.durationMinutes > 5 }.count
        }

        return SleepMetrics(
            totalSleepMin: total, timeInBedMin: timeInBed,
            remMin: rem, deepMin: deep, coreMin: core, awakeMin: awake,
            efficiencyPct: efficiency, restorativePct: restorative,
            remPct: total > 0 ? rem / total * 100 : 0,
            deepPct: total > 0 ? deep / total * 100 : 0,
            wakeEvents: wakeEvents, onset: onset, wake: wake)
    }

    /// Sleep performance score.
    /// `bedtimeStdHours` is the std-dev of recent bed times (consistency).
    public static func performance(metrics m: SleepMetrics,
                                   sleepNeedMin: Double,
                                   bedtimeStdHours: Double,
                                   weights: Weights = .default) -> SleepPerformance {
        let efficiency = Stats.clamp(m.efficiencyPct / 100, 0, 1)
        let restorative = Stats.clamp(m.restorativePct / 40, 0, 1)   // 40% == perfect
        let fulfillment = sleepNeedMin > 0 ? Stats.clamp(m.totalSleepMin / sleepNeedMin, 0, 1) : 0
        let consistency = Stats.clamp(1 - (bedtimeStdHours / 2), 0, 1) // 2h std → 0

        let score = Stats.clamp(
            efficiency * weights.efficiency + restorative * weights.restorative
            + fulfillment * weights.fulfillment + consistency * weights.consistency,
            0, 1) * 100

        return SleepPerformance(score: score,
                                efficiencyScore: efficiency * 100,
                                restorativeScore: restorative * 100,
                                needFulfillment: fulfillment * 100,
                                consistencyScore: consistency * 100)
    }
}
