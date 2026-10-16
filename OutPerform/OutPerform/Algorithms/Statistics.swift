//
//  Statistics.swift
//  OutPerform
//
//  Small, dependency-free statistics helpers used across every score.
//

import Foundation

nonisolated public enum Stats {

    public static func mean(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        return xs.reduce(0, +) / Double(xs.count)
    }

    /// Sample standard deviation (N-1). Returns 0 for fewer than 2 values.
    public static func stdDev(_ xs: [Double]) -> Double {
        guard xs.count > 1 else { return 0 }
        let m = mean(xs)
        let ss = xs.reduce(0) { $0 + ($1 - m) * ($1 - m) }
        return (ss / Double(xs.count - 1)).squareRoot()
    }

    /// Linear-interpolated percentile. `p` in 0...1.
    public static func percentile(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let sorted = xs.sorted()
        if sorted.count == 1 { return sorted[0] }
        let rank = clamp(p, 0, 1) * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        let frac = rank - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * frac
    }

    public static func median(_ xs: [Double]) -> Double { percentile(xs, 0.5) }

    /// z-score of `value` against a baseline mean/std. Std of 0 yields 0.
    public static func zScore(_ value: Double, mean: Double, std: Double) -> Double {
        guard std > 0 else { return 0 }
        return (value - mean) / std
    }

    public static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        Swift.min(hi, Swift.max(lo, x))
    }

    /// One step of an exponentially weighted moving average.
    public static func ewma(previous: Double, value: Double, lambda: Double) -> Double {
        value * lambda + previous * (1 - lambda)
    }

    /// Least-squares slope of y vs x (used by DFA and trend lines).
    public static func slope(x: [Double], y: [Double]) -> Double {
        let n = Double(min(x.count, y.count))
        guard n > 1 else { return 0 }
        let mx = mean(x), my = mean(y)
        var num = 0.0, den = 0.0
        for i in 0..<Int(n) {
            num += (x[i] - mx) * (y[i] - my)
            den += (x[i] - mx) * (x[i] - mx)
        }
        return den == 0 ? 0 : num / den
    }
}
