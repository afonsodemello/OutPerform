//
//  RespirationFromBeats.swift
//  OutPerform
//
//  Breathing rate without a respiration sensor. Heart rate speeds up on each
//  in-breath and slows on each out-breath (respiratory sinus arrhythmia), so
//  the beat-to-beat interval series carries a breathing wave. During sleep,
//  when RSA is strongest, its peaks give a usable breathing rate.
//
//  Pipeline (simple peak detector, as NOOP uses for its resp channel):
//   clean beats → resample to 4 Hz → subtract a 12 s moving average
//   (detrend) → 1 s moving average (smooth) → local maxima ≥ 2 s apart →
//   breath intervals kept within 1.5–12 s → rate = 60 / median interval,
//   RRV (respiratory-rate variability) = SD of the intervals.
//

import Foundation

nonisolated public struct RespirationEstimate: Sendable {
    public var breathsPerMinute: Double
    /// SD of breath-to-breath intervals (s). Irregular breathing → REM signal.
    public var variability: Double
}

nonisolated public enum RespirationFromBeats {
    static let fs = 4.0

    public static func estimate(_ beats: [RRBeat]) -> RespirationEstimate? {
        let clean = BeatHRV.clean(beats)
        guard clean.count >= 30, let first = clean.first, let last = clean.last,
              last.t - first.t >= 60 else { return nil }

        // Resample to an even 4 Hz grid by linear interpolation.
        var series: [Double] = []
        var j = 0
        var t = first.t
        while t <= last.t {
            while j + 1 < clean.count, clean[j + 1].t < t { j += 1 }
            guard j + 1 < clean.count else { break }
            let a = clean[j], b = clean[j + 1]
            // Don't interpolate across a dropout.
            if b.t - a.t > BeatHRV.maxBeatGapS { series.append(.nan) } else {
                let f = (t - a.t) / max(b.t - a.t, 1e-6)
                series.append(a.rr + (b.rr - a.rr) * f)
            }
            t += 1 / fs
        }
        guard series.count >= Int(60 * fs) else { return nil }

        let trend = movingAverage(series, window: Int(12 * fs))
        let detrended = zip(series, trend).map { $0 - $1 }
        let smooth = movingAverage(detrended, window: Int(fs))

        // Local maxima above zero, at least 2 s apart (keep the taller one).
        let minSep = Int(2 * fs)
        var peaks: [Int] = []
        for i in 1..<(smooth.count - 1) {
            let v = smooth[i]
            guard v.isFinite, v > 0, v >= smooth[i - 1], v > smooth[i + 1] else { continue }
            if let p = peaks.last, i - p < minSep {
                if v > smooth[p] { peaks[peaks.count - 1] = i }
            } else {
                peaks.append(i)
            }
        }
        var intervals: [Double] = []
        for k in 1..<max(peaks.count, 1) {
            let dt = Double(peaks[k] - peaks[k - 1]) / fs
            // A NaN between peaks means a dropout: skip that interval.
            let gapped = smooth[peaks[k - 1]...peaks[k]].contains { !$0.isFinite }
            if !gapped, dt >= 1.5, dt <= 12 { intervals.append(dt) }
        }
        guard intervals.count >= 3 else { return nil }
        let rate = 60 / Stats.median(intervals)
        guard rate >= 5, rate <= 35 else { return nil }
        return RespirationEstimate(breathsPerMinute: rate, variability: Stats.stdDev(intervals))
    }

    /// Centred moving average that skips NaNs (NaN where the window is empty).
    static func movingAverage(_ x: [Double], window: Int) -> [Double] {
        guard window > 1 else { return x }
        let half = window / 2
        var prefix = [Double](repeating: 0, count: x.count + 1)
        var counts = [Int](repeating: 0, count: x.count + 1)
        for i in x.indices {
            let ok = x[i].isFinite
            prefix[i + 1] = prefix[i] + (ok ? x[i] : 0)
            counts[i + 1] = counts[i] + (ok ? 1 : 0)
        }
        return x.indices.map { i in
            let lo = max(0, i - half), hi = min(x.count, i + half + 1)
            let n = counts[hi] - counts[lo]
            return n > 0 && x[i].isFinite ? (prefix[hi] - prefix[lo]) / Double(n) : .nan
        }
    }
}
