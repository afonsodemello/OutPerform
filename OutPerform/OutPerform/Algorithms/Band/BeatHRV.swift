//
//  BeatHRV.swift
//  OutPerform
//
//  Time-domain HRV from beat-to-beat intervals recorded by the band, with a
//  deterministic cleaning pipeline:
//
//   1. Range filter: keep 300–2000 ms (≈200–30 bpm).
//   2. Ectopic rejection (Malik et al. 1989): drop a beat that deviates more
//      than 20% from the median of its 5-beat centred neighbourhood.
//   3. Sufficiency gate: at least 20 clean beats, or no result.
//
//  RMSSD / SDNN / pNN50 follow the Task Force (1996) definitions.
//

import Foundation

nonisolated public struct BeatHRVResult: Sendable {
    public var rmssd: Double
    public var sdnn: Double
    public var meanNN: Double
    public var pnn50: Double
    public var nInput: Int
    public var nClean: Int
}

nonisolated public enum BeatHRV {
    public static let rrMinMs = 300.0
    public static let rrMaxMs = 2000.0
    public static let ectopicThreshold = 0.20
    public static let ectopicRadius = 2
    public static let minBeats = 20
    /// Two beats further apart than this are not consecutive (dropout / gap),
    /// so their difference must not enter RMSSD.
    public static let maxBeatGapS = 3.0

    /// Range filter + local-median ectopic rejection. Order is preserved.
    public static func clean(_ beats: [RRBeat]) -> [RRBeat] {
        let ranged = beats.filter { $0.rr >= rrMinMs && $0.rr <= rrMaxMs }
        guard ranged.count > 2 * ectopicRadius else { return ranged }
        var out: [RRBeat] = []
        out.reserveCapacity(ranged.count)
        for i in ranged.indices {
            let lo = max(0, i - ectopicRadius), hi = min(ranged.count - 1, i + ectopicRadius)
            if hi - lo < 2 * ectopicRadius { out.append(ranged[i]); continue }   // edge: keep
            let neighbourhood = ranged[lo...hi].map(\.rr).sorted()
            let med = neighbourhood[neighbourhood.count / 2]
            if abs(ranged[i].rr - med) <= ectopicThreshold * med { out.append(ranged[i]) }
        }
        return out
    }

    /// Clean then compute. Successive differences are only taken between
    /// beats that are genuinely consecutive in time.
    public static func analyze(_ beats: [RRBeat]) -> BeatHRVResult? {
        let clean = clean(beats)
        guard clean.count >= minBeats else { return nil }
        let rr = clean.map(\.rr)
        var sumSq = 0.0, nDiff = 0, n50 = 0
        for i in 1..<clean.count {
            // The later beat's time minus its own interval should land on the
            // earlier beat; a bigger jump means beats were dropped between them.
            let gap = clean[i].t - clean[i - 1].t
            guard gap <= maxBeatGapS else { continue }
            let d = clean[i].rr - clean[i - 1].rr
            sumSq += d * d
            nDiff += 1
            if abs(d) > 50 { n50 += 1 }
        }
        guard nDiff >= minBeats - 1 else { return nil }
        return BeatHRVResult(
            rmssd: (sumSq / Double(nDiff)).squareRoot(),
            sdnn: Stats.stdDev(rr),
            meanNN: Stats.mean(rr),
            pnn50: 100 * Double(n50) / Double(nDiff),
            nInput: beats.count,
            nClean: clean.count)
    }

    /// Mean RMSSD over 5-minute tumbling windows (NOOP's per-session HRV).
    /// Averaging windows instead of one long series keeps a short noisy stretch
    /// from dominating the night.
    public static func windowedRMSSD(_ beats: [RRBeat], from start: Double, to end: Double,
                                     windowS: Double = 300) -> (mean: Double, windows: [(t: Double, rmssd: Double)])? {
        guard end > start else { return nil }
        var windows: [(t: Double, rmssd: Double)] = []
        var idx = beats.partitionIndex { $0.t < start }
        var w = start
        while w <= end {
            let wEnd = min(w + windowS, end)
            var bucket: [RRBeat] = []
            // Bins are [t, t+300) except the final one, which is closed.
            while idx < beats.count, beats[idx].t < wEnd || (wEnd == end && beats[idx].t <= end) {
                if beats[idx].t >= w { bucket.append(beats[idx]) }
                idx += 1
            }
            if let r = analyze(bucket) { windows.append((w + (wEnd - w) / 2, r.rmssd)) }
            if wEnd >= end { break }
            w = wEnd
        }
        guard !windows.isEmpty else { return nil }
        return (Stats.mean(windows.map(\.rmssd)), windows)
    }
}

extension Array {
    /// First index where `belongsBefore` is false (array must be partitioned).
    nonisolated func partitionIndex(where belongsBefore: (Element) -> Bool) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if belongsBefore(self[mid]) { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
