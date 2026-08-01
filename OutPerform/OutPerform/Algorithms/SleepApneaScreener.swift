//
//  SleepApneaScreener.swift
//  OutPerform
//
//  Overnight SpO2 screening for sleep-disordered breathing via the Oxygen
//  Desaturation Index Screening only, never a diagnosis.
//

import Foundation

public struct ApneaScreeningResult: Sendable {
    public var odi: Double                  // events per hour of sleep
    public var desaturationEvents: Int
    public var minSpO2: Double
    public var meanSpO2: Double
    public var pctTimeBelow90: Double
    public var risk: ApneaRisk
}

public enum SleepApneaScreener {

    /// Count desaturations ≥3% below a rolling baseline lasting ≥10s, then the
    /// Oxygen Desaturation Index = events / sleep-hours.
    ///
    /// `samples` are SpO2 percentages (e.g. 96.0) during the sleep window.
    public static func screen(spo2 samples: [QuantitySample], sleepHours: Double) -> ApneaScreeningResult? {
        let sorted = samples.sorted { $0.start < $1.start }
        guard sorted.count >= 5, sleepHours > 0 else { return nil }

        let values = sorted.map(\.value)
        let baseline = Stats.percentile(values, 0.9)   // robust "normal" level
        let minSpO2 = values.min() ?? 0
        let meanSpO2 = Stats.mean(values)

        // Time-weighted % of samples below 90.
        let below90 = sorted.filter { $0.value < 90 }
        let totalSpan = max(sorted.last!.end.timeIntervalSince(sorted.first!.start), 1)
        let below90Span = below90.reduce(0.0) { $0 + max($1.end.timeIntervalSince($1.start), 1) }
        let pctBelow90 = below90Span / totalSpan * 100

        // Desaturation event: a run dipping ≥3% below baseline for ≥10s.
        var events = 0
        var runStart: Date? = nil
        var inDip = false
        for s in sorted {
            let isDip = (baseline - s.value) >= 3
            if isDip && !inDip {
                inDip = true; runStart = s.start
            } else if !isDip && inDip {
                if let rs = runStart, s.start.timeIntervalSince(rs) >= 10 { events += 1 }
                inDip = false; runStart = nil
            }
        }
        if inDip, let rs = runStart, let last = sorted.last,
           last.end.timeIntervalSince(rs) >= 10 { events += 1 }

        let odi = Double(events) / sleepHours
        return ApneaScreeningResult(odi: odi, desaturationEvents: events,
                                    minSpO2: minSpO2, meanSpO2: meanSpO2,
                                    pctTimeBelow90: pctBelow90, risk: ApneaRisk(odi: odi))
    }
}
