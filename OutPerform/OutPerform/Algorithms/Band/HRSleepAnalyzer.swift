//
//  HRSleepAnalyzer.swift
//  OutPerform
//
//  Finds the night's sleep and stages it from heart rate and heartbeat
//  intervals alone. The Fitbit Air's open Bluetooth profile has no
//  accelerometer channel, so where NOOP's stager uses gravity stillness as its
//  sleep/wake spine, this one uses the overnight heart-rate drop: sleeping HR
//  settles into a band well below your waking HR, and stays there.
//
//  Detection (per night window, previous 18:00 → 14:00):
//   1. 1-minute mean HR, smoothed by a centred 15-minute rolling median.
//   2. Sleep band = floor + 45% of (waking reference − floor), where floor is
//      the 5th percentile of the smoothed night and the reference is your
//      daytime median HR (or the night's 75th percentile when unknown).
//   3. Minutes inside the band are "sleep". Runs shorter than 15 min are
//      absorbed into their neighbours, runs break on data gaps > 20 min, a
//      run must last ≥ 60 min, and runs < 60 min apart bridge into one night.
//
//  Staging (30-second epochs over a centred 5-minute window), following the
//  percentile-band approach NOOP documents:
//   • features: mean HR, Walch difference-of-Gaussians HR variability
//     (σ 120 s − σ 600 s), RMSSD from the beats, breathing-rate variability
//     from the RSA wave in the beats;
//   • wake  = HR high for the night and DoG activation high;
//   • deep  = low HR + high parasympathetic tone (RMSSD) + regular breathing;
//   • REM   = cardiac activation + irregular breathing;
//   • light = everything else;
//   • 5-epoch mode smoothing, no REM in the first 15 min after onset, no deep
//     in the second half of the night (motionless HR-only staging can't
//     separate late deep from quiet light reliably).
//
//  Honest limits: EEG-free staging tops out around 65–73% epoch agreement,
//  and without motion the wake/light boundary is the weakest. These stages
//  are approximations, not a medical measurement.
//

import Foundation

nonisolated public struct BandSleepSession: Sendable {
    public var start: Date
    public var end: Date
    public var segments: [SleepSegment]
    /// Lowest sustained HR: minimum 5-minute bin mean.
    public var restingHR: Double?
    /// Mean of 5-minute-window RMSSDs (ms).
    public var rmssd: Double?
    public var sdnn: Double?
    public var respiratoryRate: Double?
    public var hasBeatData: Bool
}

nonisolated public enum HRSleepAnalyzer {
    public static let smoothWindowMin = 15
    public static let mergeMin = 15
    public static let maxGapMin = 20
    public static let minSleepMin = 60
    public static let bridgeMaxMin = 60
    public static let bandFraction = 0.45
    static let epochS = 30.0

    /// Detect and stage the main sleep session inside `[windowStart, windowEnd]`.
    /// - Parameter wakingReferenceHR: your typical daytime HR, if known.
    public static func analyzeNight(hr: [HRPoint], beats: [RRBeat],
                                    windowStart: Date, windowEnd: Date,
                                    wakingReferenceHR: Double?) -> BandSleepSession? {
        let w0 = windowStart.timeIntervalSince1970, w1 = windowEnd.timeIntervalSince1970
        let points = hr.filter { $0.t >= w0 && $0.t <= w1 }
        guard points.count >= 120 else { return nil }

        // 1. Minute grid.
        let nMin = Int((w1 - w0) / 60) + 1
        var sums = [Double](repeating: 0, count: nMin), counts = [Int](repeating: 0, count: nMin)
        for p in points {
            let m = Int((p.t - w0) / 60)
            guard m >= 0, m < nMin else { continue }
            sums[m] += p.bpm; counts[m] += 1
        }
        let minuteHR: [Double?] = (0..<nMin).map { counts[$0] > 0 ? sums[$0] / Double(counts[$0]) : nil }
        guard minuteHR.compactMap({ $0 }).count >= 120 else { return nil }

        // Centred rolling median.
        let half = smoothWindowMin / 2
        let smooth: [Double?] = (0..<nMin).map { i in
            guard minuteHR[i] != nil else { return nil }
            let vals = minuteHR[max(0, i - half)...min(nMin - 1, i + half)].compactMap { $0 }
            return vals.count >= 5 ? Stats.median(vals) : minuteHR[i]
        }
        let valid = smooth.compactMap { $0 }
        let floorHR = Stats.percentile(valid, 0.05)
        var reference = wakingReferenceHR ?? Stats.percentile(valid, 0.75)
        if reference - floorHR < 8 { reference = floorHR + 8 }
        let threshold = floorHR + bandFraction * (reference - floorHR)

        // 2. Label minutes: true = sleep, false = wake, nil = no data.
        var label: [Bool?] = smooth.map { $0.map { $0 <= threshold } }

        // 3a. Absorb short runs into their neighbours (both sides agree).
        absorbShortRuns(&label, maxLen: mergeMin)

        // 3b. Sleep runs, breaking on long gaps.
        var runs: [(s: Int, e: Int)] = []
        var i = 0
        while i < nMin {
            guard label[i] == true else { i += 1; continue }
            var j = i, lastSleep = i, gap = 0
            while j + 1 < nMin {
                let next = label[j + 1]
                if next == true { gap = 0; lastSleep = j + 1 }
                else if next == nil { gap += 1; if gap > maxGapMin { break } }
                else { break }
                j += 1
            }
            runs.append((i, lastSleep))
            i = j + 1
        }
        runs = runs.filter { $0.e - $0.s + 1 >= minSleepMin }
        guard !runs.isEmpty else { return nil }

        // 3c. Bridge runs that sit < 60 min apart into nights; keep the longest.
        var nights: [[(s: Int, e: Int)]] = [[runs[0]]]
        for r in runs.dropFirst() {
            if r.s - nights[nights.count - 1].last!.e <= bridgeMaxMin { nights[nights.count - 1].append(r) }
            else { nights.append([r]) }
        }
        let main = nights.max { a, b in
            a.reduce(0) { $0 + $1.e - $1.s } < b.reduce(0) { $0 + $1.e - $1.s }
        }!
        let start = w0 + Double(main.first!.s) * 60
        let end = w0 + Double(main.last!.e + 1) * 60

        let sessionHR = points.filter { $0.t >= start && $0.t <= end }
        let sessionBeats = beats.filter { $0.t >= start && $0.t <= end }
        let segments = stage(hr: sessionHR, beats: sessionBeats, start: start, end: end,
                             wakeThreshold: threshold)
        guard let first = segments.first(where: { $0.stage.isAsleep }),
              let last = segments.last(where: { $0.stage.isAsleep }) else { return nil }
        let trimmed = segments.filter { $0.end > first.start && $0.start < last.end }

        let s0 = first.start.timeIntervalSince1970, s1 = last.end.timeIntervalSince1970
        let hrIn = sessionHR.filter { $0.t >= s0 && $0.t <= s1 }
        let beatsIn = sessionBeats.filter { $0.t >= s0 && $0.t <= s1 }
        let asleepIntervals = trimmed.filter { $0.stage.isAsleep }
            .map { ($0.start.timeIntervalSince1970, $0.end.timeIntervalSince1970) }
        let asleepBeats = beatsIn.filter { b in asleepIntervals.contains { b.t >= $0.0 && b.t <= $0.1 } }

        return BandSleepSession(
            start: first.start, end: last.end, segments: trimmed,
            restingHR: restingHR(hrIn, from: s0, to: s1),
            rmssd: BeatHRV.windowedRMSSD(asleepBeats, from: s0, to: s1)?.mean,
            sdnn: BeatHRV.analyze(asleepBeats)?.sdnn,
            respiratoryRate: respirationRate(asleepBeats, from: s0, to: s1),
            hasBeatData: !beatsIn.isEmpty)
    }

    // MARK: Resting HR

    /// Minimum of 5-minute bin means. A bin only wins with ≥ 5 samples and a
    /// mean ≥ 25 bpm, so a dropout edge can't become the night's floor.
    public static func restingHR(_ hr: [HRPoint], from start: Double, to end: Double) -> Double? {
        guard !hr.isEmpty, end >= start else { return nil }
        let nBins = max(1, Int(ceil((end - start) / 300)))
        var sums = [Double](repeating: 0, count: nBins), counts = [Int](repeating: 0, count: nBins)
        for p in hr where p.t >= start && p.t <= end {
            let b = min(nBins - 1, Int((p.t - start) / 300))
            sums[b] += p.bpm; counts[b] += 1
        }
        let means = (0..<nBins).compactMap { counts[$0] > 0 ? (sums[$0] / Double(counts[$0]), counts[$0]) : nil }
        if let best = means.filter({ $0.1 >= 5 && $0.0 >= 25 }).map(\.0).min() { return best }
        if let any = means.map(\.0).min() { return any }
        return Stats.mean(hr.map(\.bpm))
    }

    /// Median breathing rate over 5-minute windows of asleep beats.
    static func respirationRate(_ beats: [RRBeat], from start: Double, to end: Double) -> Double? {
        var rates: [Double] = []
        var w = start
        var idx = 0
        while w < end {
            let wEnd = w + 300
            var bucket: [RRBeat] = []
            while idx < beats.count, beats[idx].t < wEnd {
                if beats[idx].t >= w { bucket.append(beats[idx]) }
                idx += 1
            }
            if let r = RespirationFromBeats.estimate(bucket) { rates.append(r.breathsPerMinute) }
            w = wEnd
        }
        return rates.count >= 3 ? Stats.median(rates) : nil
    }

    // MARK: Staging

    enum Stage: Int { case wake, light, deep, rem }

    static func stage(hr: [HRPoint], beats: [RRBeat], start: Double, end: Double,
                      wakeThreshold: Double) -> [SleepSegment] {
        let n = max(1, Int((end - start) / epochS))
        // Per-epoch mean HR, gaps filled by linear interpolation.
        var sums = [Double](repeating: 0, count: n), counts = [Int](repeating: 0, count: n)
        for p in hr {
            let e = Int((p.t - start) / epochS)
            guard e >= 0, e < n else { continue }
            sums[e] += p.bpm; counts[e] += 1
        }
        var epochHR: [Double] = (0..<n).map { counts[$0] > 0 ? sums[$0] / Double(counts[$0]) : .nan }
        interpolateNaNs(&epochHR)

        // Walch DoG: σ = 120 s and 600 s → 4 and 20 epochs.
        let g1 = gaussianSmooth(epochHR, sigma: 4)
        let g2 = gaussianSmooth(epochHR, sigma: 20)
        let dog = zip(g1, g2).map { abs($0 - $1) }

        // 5-minute centred window features (±5 epochs).
        let halfW = 5
        var meanHR = [Double](repeating: .nan, count: n)
        var rmssd = [Double](repeating: .nan, count: n)
        var rrv = [Double](repeating: .nan, count: n)
        var bIdx = 0
        // Breathing variability is costly; compute it every 4th epoch and reuse.
        var lastRRV = Double.nan
        for e in 0..<n {
            let lo = max(0, e - halfW), hi = min(n - 1, e + halfW)
            meanHR[e] = Stats.mean(Array(epochHR[lo...hi]))
            if !beats.isEmpty {
                let t0 = start + Double(lo) * epochS, t1 = start + Double(hi + 1) * epochS
                while bIdx < beats.count, beats[bIdx].t < t0 { bIdx += 1 }
                var k = bIdx
                var window: [RRBeat] = []
                while k < beats.count, beats[k].t < t1 { window.append(beats[k]); k += 1 }
                if let r = BeatHRV.analyze(window) { rmssd[e] = r.rmssd }
                if e % 4 == 0 { lastRRV = RespirationFromBeats.estimate(window)?.variability ?? .nan }
                rrv[e] = lastRRV
            }
        }

        func pct(_ xs: [Double], _ p: Double) -> Double? {
            let v = xs.filter(\.isFinite)
            return v.count >= 10 ? Stats.percentile(v, p) : nil
        }
        let hr90 = pct(meanHR, 0.90) ?? .infinity, hr50 = pct(meanHR, 0.50) ?? 0
        let hr30 = pct(meanHR, 0.35) ?? 0
        let dog90 = pct(dog, 0.90) ?? .infinity
        let dog75 = pct(dog, 0.75) ?? .infinity, dog60 = pct(dog, 0.60) ?? .infinity
        let dog50 = pct(dog, 0.50) ?? .infinity
        let rm65 = pct(rmssd, 0.65), rm40 = pct(rmssd, 0.40)
        let rrv65 = pct(rrv, 0.65), rrv50 = pct(rrv, 0.50)

        var labels = [Stage](repeating: .light, count: n)
        for e in 0..<n {
            let h = meanHR[e], d = dog[e], r = rmssd[e], v = rrv[e]
            // Without motion, elevated-but-steady HR is not enough to call
            // wake (that's usually REM): require leaving the sleep band, or a
            // sharp arousal spike well above the night's median.
            if h > wakeThreshold || (h >= hr90 && d >= dog90 && h >= hr50 + 8) {
                labels[e] = .wake; continue
            }
            let parasympathetic = rm65.map { r.isFinite && r >= $0 } ?? (d <= dog50)
            let regularBreathing = rrv50.map { !v.isFinite || v <= $0 } ?? true
            if h <= hr30, parasympathetic, regularBreathing, d <= dog75 {
                labels[e] = .deep; continue
            }
            let irregular: Bool
            if let q = rrv65, v.isFinite { irregular = v >= q }
            else if let q = rm40, r.isFinite { irregular = r <= q }
            else { irregular = d >= dog75 }
            if h >= hr50, (irregular && d >= dog50) || (d >= dog60 && h >= hr90) { labels[e] = .rem }
        }

        labels = modeSmooth(labels, radius: 2)

        // Physiology: no REM in the first 15 min after onset; slow-wave sleep
        // is concentrated early, so none in the second half of the night.
        if let onset = labels.firstIndex(where: { $0 != .wake }) {
            for e in onset..<min(n, onset + 30) where labels[e] == .rem { labels[e] = .light }
        }
        for e in (n / 2)..<n where labels[e] == .deep { labels[e] = .light }

        // Merge epochs into segments.
        var segments: [SleepSegment] = []
        var runStart = 0
        for e in 1...n {
            if e == n || labels[e] != labels[runStart] {
                let s = Date(timeIntervalSince1970: start + Double(runStart) * epochS)
                let en = Date(timeIntervalSince1970: e == n ? end : start + Double(e) * epochS)
                segments.append(SleepSegment(start: s, end: en, stage: sleepStage(labels[runStart])))
                runStart = e
            }
        }
        return segments
    }

    static func sleepStage(_ s: Stage) -> SleepStage {
        switch s {
        case .wake:  return .awake
        case .light: return .core
        case .deep:  return .deep
        case .rem:   return .rem
        }
    }

    // MARK: Signal helpers

    /// Flip runs of ≤ `maxLen` minutes whose neighbours on both sides agree
    /// with each other and differ from the run.
    static func absorbShortRuns(_ label: inout [Bool?], maxLen: Int) {
        var changed = true
        var passes = 0
        while changed && passes < 4 {
            changed = false; passes += 1
            var i = 0
            while i < label.count {
                guard let v = label[i] else { i += 1; continue }
                var j = i
                while j + 1 < label.count, label[j + 1] == v { j += 1 }
                let len = j - i + 1
                let before = label[..<i].last { $0 != nil } ?? nil
                let after = label[(j + 1)...].first { $0 != nil } ?? nil
                if len <= maxLen, let b = before, let a = after, a == b, a != v {
                    for k in i...j { label[k] = a }
                    changed = true
                }
                i = j + 1
            }
        }
    }

    static func interpolateNaNs(_ x: inout [Double]) {
        let known = x.indices.filter { x[$0].isFinite }
        guard let first = known.first, let last = known.last else {
            for i in x.indices { x[i] = 60 }
            return
        }
        for i in 0..<first { x[i] = x[first] }
        for i in (last + 1)..<x.count { x[i] = x[last] }
        var prev = first
        for k in known.dropFirst() {
            if k - prev > 1 {
                for i in (prev + 1)..<k {
                    let f = Double(i - prev) / Double(k - prev)
                    x[i] = x[prev] + (x[k] - x[prev]) * f
                }
            }
            prev = k
        }
    }

    /// Gaussian smoothing with reflect padding.
    static func gaussianSmooth(_ x: [Double], sigma: Double) -> [Double] {
        let radius = Int(ceil(3 * sigma))
        let kernel = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let norm = kernel.reduce(0, +)
        let n = x.count
        guard n > 0 else { return x }
        func reflect(_ i: Int) -> Int {
            guard n > 1 else { return 0 }
            var j = i
            while j < 0 || j >= n { j = j < 0 ? -j - 1 : 2 * n - j - 1 }
            return j
        }
        return (0..<n).map { i in
            var acc = 0.0
            for (k, w) in kernel.enumerated() { acc += w * x[reflect(i + k - radius)] }
            return acc / norm
        }
    }

    static func modeSmooth(_ labels: [Stage], radius: Int) -> [Stage] {
        labels.indices.map { i in
            let window = labels[max(0, i - radius)...min(labels.count - 1, i + radius)]
            var counts: [Stage: Int] = [:]
            for l in window { counts[l, default: 0] += 1 }
            let best = counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key != labels[i]) }!
            return best.value > window.count / 2 ? best.key : labels[i]
        }
    }
}
