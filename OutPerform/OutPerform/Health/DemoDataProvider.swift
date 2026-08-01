//
//  DemoDataProvider.swift
//  OutPerform
//
//  Generates 30 days of realistic synthetic health data so reviewers and
//  new users can explore the full app without a wearable.
//
//  Design goals:
//  • Sleep 6h45m–8h30m per night with natural day-to-day variation.
//  • HRV/RHR react to workout days (higher load → lower HRV next morning).
//  • All signals stay within clinically normal ranges for a fit adult.
//  • Deterministic — same values every launch, so the UI is reviewable.
//
//  IMPORTANT: switching away from Demo to a real source wipes all stored
//  DailyRecords so no demo values bleed into live data.
//

import Foundation

final class DemoDataProvider: HealthDataProvider {

    let sourceType: DataSourceType = .demo

    func isAvailable() -> Bool { true }
    func requestAuthorization() async throws { }

    // MARK: - PRNG

    private static let seed: UInt64 = 0xCAFEBABE_DEADBEEF

    /// Deterministic pseudo-random Double in [lo, hi) keyed by (day-offset, slot).
    private func rnd(_ offset: Int, _ slot: Int, lo: Double = 0, hi: Double = 1) -> Double {
        var x = UInt64(bitPattern: Int64(offset &* 92821 &+ slot &* 6364136223846793005))
        x ^= DemoDataProvider.seed
        x = x &* 6364136223846793005 &+ 1442695040888963407
        x ^= x >> 33; x = x &* 0xff51afd7ed558ccd
        x ^= x >> 33; x = x &* 0xc4ceb9fe1a85ec53
        x ^= x >> 33
        let frac = Double(x & 0x000FFFFFFFFFFFFF) / Double(0x000FFFFFFFFFFFFF)
        return lo + frac * (hi - lo)
    }

    private let cal = Calendar.current

    private func dayStart(_ offset: Int, from now: Date) -> Date {
        cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now))!
    }

    // Workout days (offset from today) and their approximate strain level 0–21.
    private let workoutSchedule: [(Int, WorkoutActivity, Double, Double)] = [
        // (offset, activity, duration-min, approx-strain)
        (  0, .running,       45, 13.5),
        ( -2, .weightlifting, 55, 11.0),
        ( -4, .running,       30,  9.0),
        ( -7, .hiit,          40, 15.0),
        ( -9, .cycling,       60, 12.0),
        (-11, .weightlifting, 50, 10.5),
        (-14, .running,       50, 13.0),
        (-16, .cycling,       45, 11.5),
        (-18, .running,       35,  9.5),
        (-21, .hiit,          45, 14.5),
        (-23, .weightlifting, 60, 11.0),
        (-25, .running,       40, 10.0),
        (-28, .cycling,       55, 12.5),
    ]

    private func strainOnDay(_ offset: Int) -> Double {
        workoutSchedule.first(where: { $0.0 == offset })?.2 ?? 2.0
    }

    // MARK: - Heart Rate

    func heartRates(from: Date, to: Date) async throws -> [QuantitySample] {
        let now = Date()
        var out = [QuantitySample]()
        for offset in stride(from: -30, through: 0, by: 1) {
            let day = dayStart(offset, from: now)
            let isWorkout = workoutSchedule.contains(where: { $0.0 == offset })
            // Personal resting HR varies 52–66 bpm with mild day-to-day noise.
            let hrBase = 57.0 + rnd(offset, 1, lo: -5, hi: 8)

            // Overnight (00:00–06:30): every 5 min near resting HR
            for m in stride(from: 0, through: 390, by: 5) {
                let t = cal.date(byAdding: .minute, value: m, to: day)!
                guard t >= from, t <= to else { continue }
                out.append(.init(start: t, end: t.addingTimeInterval(60),
                                 value: hrBase + rnd(offset, 100 + m, lo: -4, hi: 4)))
            }
            // Day (07:00–22:00): every 10 min, active range 65–95
            let dayBegin = cal.date(byAdding: .hour, value: 7, to: day)!
            for m in stride(from: 0, through: 900, by: 10) {
                let t = cal.date(byAdding: .minute, value: m, to: dayBegin)!
                guard t >= from, t <= to else { continue }
                out.append(.init(start: t, end: t.addingTimeInterval(60),
                                 value: hrBase + rnd(offset, 500 + m, lo: 8, hi: 32)))
            }
            // Workout (10:00): 1-min samples at elevated HR
            if isWorkout, let (_, _, dur, _) = workoutSchedule.first(where: { $0.0 == offset }) {
                let ws = cal.date(byAdding: .hour, value: 10, to: day)!
                for m in 0...Int(dur) {
                    let t = cal.date(byAdding: .minute, value: m, to: ws)!
                    guard t >= from, t <= to else { continue }
                    // HR ramps up, peaks mid-workout, comes down
                    let phase = Double(m) / dur
                    let peak = 125.0 + rnd(offset, 2000 + m, lo: 0, hi: 40)
                    let rampFactor = phase < 0.15 ? phase/0.15 : (phase < 0.80 ? 1.0 : (1.0-phase)/0.20)
                    out.append(.init(start: t, end: t.addingTimeInterval(60),
                                     value: hrBase + 15 + peak * rampFactor))
                }
            }
        }
        return out
    }

    // MARK: - Beat-to-beat RR

    func beatToBeatRR(from: Date, to: Date) async throws -> [QuantitySample] { [] }

    // MARK: - HRV (SDNN)
    // Lower after hard workouts, higher after easy/rest days.

    func hrvSDNN(from: Date, to: Date) async throws -> [QuantitySample] {
        let now = Date()
        var out = [QuantitySample]()
        for offset in stride(from: -30, through: 0, by: 1) {
            // HRV measured at wake (~06:30)
            let t = cal.date(byAdding: .minute, value: 6*60+30, to: dayStart(offset, from: now))!
            guard t >= from, t <= to else { continue }

            let prevStrain = strainOnDay(offset - 1)  // yesterday's strain suppresses HRV
            let suppressionFactor = max(0, (prevStrain - 5) / 15)  // 0 at strain≤5, 1 at strain=20
            let base = 58.0 - suppressionFactor * 22.0  // 36–58 ms
            let v = base + rnd(offset, 10, lo: -8, hi: 10)
            out.append(.init(date: t, value: max(25, v)))
        }
        return out
    }

    // MARK: - Resting HR
    // Slightly elevated after hard workouts.

    func restingHeartRate(from: Date, to: Date) async throws -> [QuantitySample] {
        let now = Date()
        var out = [QuantitySample]()
        for offset in stride(from: -30, through: 0, by: 1) {
            let t = cal.date(byAdding: .hour, value: 7, to: dayStart(offset, from: now))!
            guard t >= from, t <= to else { continue }

            let prevStrain = strainOnDay(offset - 1)
            let elevationFactor = max(0, (prevStrain - 5) / 15)
            let v = 54.0 + elevationFactor * 8.0 + rnd(offset, 20, lo: -3, hi: 5)
            out.append(.init(date: t, value: v))
        }
        return out
    }

    // MARK: - Respiratory Rate

    func respiratoryRate(from: Date, to: Date) async throws -> [QuantitySample] {
        let now = Date()
        var out = [QuantitySample]()
        for offset in stride(from: -30, through: 0, by: 1) {
            let t = cal.date(byAdding: .hour, value: 3, to: dayStart(offset, from: now))!
            guard t >= from, t <= to else { continue }
            out.append(.init(date: t, value: 14.0 + rnd(offset, 30, lo: -1.0, hi: 2.5)))
        }
        return out
    }

    // MARK: - Blood Oxygen

    func oxygenSaturation(from: Date, to: Date) async throws -> [QuantitySample] {
        let now = Date()
        var out = [QuantitySample]()
        for offset in stride(from: -30, through: 0, by: 1) {
            let t = cal.date(byAdding: .hour, value: 3, to: dayStart(offset, from: now))!
            guard t >= from, t <= to else { continue }
            out.append(.init(date: t, value: 97.8 + rnd(offset, 40, lo: -1.3, hi: 1.2)))
        }
        return out
    }

    // MARK: - Skin Temperature

    func wristTemperature(from: Date, to: Date) async throws -> [QuantitySample] {
        let now = Date()
        var out = [QuantitySample]()
        for offset in stride(from: -30, through: 0, by: 1) {
            let t = cal.date(byAdding: .hour, value: 3, to: dayStart(offset, from: now))!
            guard t >= from, t <= to else { continue }
            out.append(.init(date: t, value: 35.9 + rnd(offset, 50, lo: -0.35, hi: 0.45)))
        }
        return out
    }

    // MARK: - Sleep Segments
    //
    // Architecture: 4–5 NREM/REM cycles, each ~90 min.
    // Deep sleep is concentrated in the first two cycles;
    // REM grows progressively across the night (standard ultradian pattern).
    //
    // Total asleep per night: 405–520 min (6h45m–8h40m).
    // A 7-entry weekly pattern creates natural variation (e.g. Fri/Sat longer).

    func sleepSegments(from: Date, to: Date) async throws -> [SleepSegment] {
        let now = Date()
        var out = [SleepSegment]()
        // Weekly pattern (index 0 = 30-days-ago, cycles every 7):
        // Adds minutes to the 450-min baseline.
        let weeklyBias: [Double] = [0, -30, -20, -10, 0, +30, +40]
        for offset in stride(from: -30, through: 0, by: 1) {
            let bias  = weeklyBias[abs(offset) % 7]
            let noise = rnd(offset, 70, lo: -20, hi: 20)
            let targetSleep = 450.0 + bias + noise  // 400–520 min

            let bedMinutes = 22*60 + 20 + Int(rnd(offset, 61, lo: 0, hi: 80)) // 22:20–23:40
            let bedtime    = cal.date(byAdding: .minute, value: bedMinutes,
                                      to: cal.startOfDay(for: dayStart(offset, from: now)))!
            guard bedtime >= from else { continue }

            // Sleep latency (awake in bed before falling asleep)
            let latency = 10.0 + rnd(offset, 62, lo: 0, hi: 14)

            var cursor = bedtime.addingTimeInterval(latency * 60)
            var asleepSoFar = 0.0

            // Scale factors so each night has its own deep/REM ratio
            let ds = rnd(offset, 71, lo: 0.82, hi: 1.18)   // deep scale
            let rs = rnd(offset, 72, lo: 0.82, hi: 1.18)   // REM scale

            func add(_ stage: SleepStage, _ mins: Double) {
                guard mins > 0 else { return }
                let end = cursor.addingTimeInterval(mins * 60)
                if cursor <= to {
                    out.append(SleepSegment(start: cursor,
                                            end: stage == .awake ? end : min(end, to),
                                            stage: stage))
                }
                if stage.isAsleep { asleepSoFar += mins }
                cursor = end
            }

            // ── Cycle 1 (~90 min, deep-dominant) ──────────────────────────
            add(.core,  22)
            add(.deep,  38 * ds)
            add(.core,  18)
            add(.rem,   14 * rs)
            add(.core,   5)
            // ── Cycle 2 (~90 min, still significant deep) ─────────────────
            add(.awake,  2)
            add(.core,  22)
            add(.deep,  24 * ds)
            add(.core,  18)
            add(.rem,   24 * rs)
            add(.core,   5)
            // ── Cycle 3 (~90 min, deep tapering, REM growing) ─────────────
            add(.core,  20)
            add(.deep,  12 * ds)
            add(.core,  22)
            add(.rem,   36 * rs)
            add(.core,   5)
            // ── Cycle 4 (~88 min, mostly REM) ─────────────────────────────
            add(.awake,  3)
            add(.core,  16)
            add(.deep,   5 * ds)
            add(.core,  20)
            add(.rem,   45 * rs)
            add(.core,   5)
            // asleepSoFar ≈ (22+38+18+14+5) + (22+24+18+24+5) + (20+12+22+36+5) + (16+5+20+45+5)
            //              ≈  97          +  93               +  95              +  91
            //              ≈ 376 min at ds=rs=1

            // ── Cycle 5 (partial, fills remainder to hit target) ──────────
            let remaining = max(0, targetSleep - asleepSoFar)
            if remaining >= 10 {
                add(.core, remaining * 0.50)
                add(.rem,  remaining * 0.38)
                add(.core, remaining * 0.12)
            }

            // In-bed wrapper (bedtime → wake) for efficiency calculation
            let wakeTime = cursor
            if wakeTime > from, wakeTime <= to {
                out.append(SleepSegment(start: bedtime, end: wakeTime, stage: .inBed))
            }
        }
        return out
    }

    // MARK: - Workouts

    func workouts(from: Date, to: Date) async throws -> [WorkoutSession] {
        let now = Date()
        var out = [WorkoutSession]()
        for (offset, activity, dur, _) in workoutSchedule {
            let day   = dayStart(offset, from: now)
            let start = cal.date(byAdding: .hour, value: 10, to: day)!
            let end   = start.addingTimeInterval(dur * 60)
            guard start >= from, end <= to else { continue }
            out.append(WorkoutSession(start: start, end: end, activity: activity,
                                      heartRates: [], activeEnergyKcal: dur * 8.5))
        }
        return out
    }

    // MARK: - VO₂ Max

    func vo2Max(from: Date, to: Date) async throws -> [QuantitySample] {
        let now = Date()
        let t = cal.date(byAdding: .day, value: -10, to: now)!
        guard t >= from, t <= to else { return [] }
        return [QuantitySample(date: t, value: 49.2)]
    }
}
