//
//  HRVAnalysis.swift
//  OutPerform
//
//  Heart-rate-variability maths. HealthKit only exposes SDNN, so we
//  reconstruct beat-to-beat (RR) intervals from the continuous heart-rate
//  stream during the sleep window and compute RMSSD ourselves,
//  plus the nonlinear DFA-alpha1 metric most trackers don't expose.
//

import Foundation

nonisolated public enum HRVAnalysis {

    /// Convert a heart-rate value in beats-per-minute to an RR interval in ms.
    public static func rrIntervalMs(fromBPM bpm: Double) -> Double {
        guard bpm > 0 else { return 0 }
        return 60_000.0 / bpm
    }

    /// RMSSD over a series of RR intervals (ms).
    /// RMSSD = sqrt( (1/(N-1)) * Σ (RR[i+1] - RR[i])^2 )
    public static func rmssd(rrIntervalsMs rr: [Double]) -> Double? {
        guard rr.count >= 2 else { return nil }
        var sumSq = 0.0
        for i in 0..<(rr.count - 1) {
            let d = rr[i + 1] - rr[i]
            sumSq += d * d
        }
        return (sumSq / Double(rr.count - 1)).squareRoot()
    }

    /// RMSSD computed from heart-rate samples (bpm) collected during sleep.
    /// Samples are sorted by time and converted to RR intervals first.
    public static func rmssd(fromHeartRates samples: [QuantitySample]) -> Double? {
        let rr = samples
            .sorted { $0.start < $1.start }
            .map { rrIntervalMs(fromBPM: $0.value) }
            .filter { $0 > 0 }
        return rmssd(rrIntervalsMs: rr)
    }

    /// SDNN — standard deviation of NN (RR) intervals. Matches HealthKit's
    /// `HeartRateVariabilitySDNN` when computed over the same window.
    public static func sdnn(rrIntervalsMs rr: [Double]) -> Double? {
        guard rr.count >= 2 else { return nil }
        return Stats.stdDev(rr)
    }

    /// Detrended Fluctuation Analysis short-term scaling exponent (alpha1).
    ///
    /// Standard Peng et al. algorithm over box sizes 4...16 beats:
    ///  1. Integrate the mean-centred RR series.
    ///  2. For each box size n, split into windows, linearly detrend each,
    ///     and take the RMS of the residuals → F(n).
    ///  3. alpha1 = slope of log F(n) vs log n.
    ///
    /// A well-recovered state sits near 1.0; sustained values < 0.8 signal
    /// lingering fatigue.
    public static func dfaAlpha1(rrIntervalsMs rr: [Double],
                                 minBox: Int = 4, maxBox: Int = 16) -> Double? {
        let n = rr.count
        guard n >= maxBox * 2 else { return nil }

        // 1. Integrated, mean-centred profile.
        let mean = Stats.mean(rr)
        var profile = [Double](repeating: 0, count: n)
        var running = 0.0
        for i in 0..<n {
            running += rr[i] - mean
            profile[i] = running
        }

        var logN: [Double] = []
        var logF: [Double] = []

        for box in minBox...maxBox {
            let windowCount = n / box
            guard windowCount >= 1 else { continue }
            var sumSqResiduals = 0.0
            var pointCount = 0
            for w in 0..<windowCount {
                let startIdx = w * box
                // x = 0...box-1, y = profile slice
                var xs = [Double](); xs.reserveCapacity(box)
                var ys = [Double](); ys.reserveCapacity(box)
                for k in 0..<box {
                    xs.append(Double(k))
                    ys.append(profile[startIdx + k])
                }
                // Linear detrend.
                let m = Stats.slope(x: xs, y: ys)
                let b = Stats.mean(ys) - m * Stats.mean(xs)
                for k in 0..<box {
                    let fit = m * xs[k] + b
                    let resid = ys[k] - fit
                    sumSqResiduals += resid * resid
                    pointCount += 1
                }
            }
            guard pointCount > 0 else { continue }
            let f = (sumSqResiduals / Double(pointCount)).squareRoot()
            guard f > 0 else { continue }
            logN.append(log(Double(box)))
            logF.append(log(f))
        }

        guard logN.count >= 2 else { return nil }
        return Stats.slope(x: logN, y: logF)
    }
}
