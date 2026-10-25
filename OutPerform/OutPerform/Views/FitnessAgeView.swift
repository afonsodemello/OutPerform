//
//  FitnessAgeView.swift
//  OutPerform
//
//  Fitness Age on the Perform tab: a summary card and a detail screen with
//  what moves the number, its trend, and other long-term health factors.
//

import SwiftUI
import SwiftData
import Charts

/// Gathers the calculator's inputs from stored days and recorded workouts.
@MainActor
enum FitnessAgeInputs {
    struct Snapshot {
        var result: FitnessAgeCalculator.Result?
        var rhrNights: Int
        var avgSleepMin: Double?
        var bedtimeSDHours: Double?
        var moderateMinutes: Double
        var vigorousMinutes: Double
        var recordedWorkouts: Int
    }

    static func snapshot(at end: Date, records: [DailyRecord], sessions: [ExerciseSession]) -> Snapshot {
        let cal = Calendar.current
        let endDay = cal.startOfDay(for: end)
        let weekStart = cal.date(byAdding: .day, value: -6, to: endDay)!
        let monthStart = cal.date(byAdding: .day, value: -27, to: endDay)!
        let lastWeek = records.filter { $0.date >= weekStart && $0.date <= endDay }
        let lastMonth = records.filter { $0.date >= monthStart && $0.date <= endDay }
        let endOfEndDay = cal.date(byAdding: .day, value: 1, to: endDay)!

        // Resting HR: last 7 nights.
        let rhrs = lastWeek.compactMap(\.restingHR)

        // Sessions in the last 28 days: recorded workouts, plus days with
        // activity strain from other sources that have no recorded workout.
        let monthSessions = sessions.filter { $0.start >= monthStart && $0.start < endOfEndDay }
        var list: [FitnessAgeCalculator.Session] = monthSessions.map { s in
            let total = max(1, s.zoneSeconds.reduce(0, +))
            let hard = s.zoneSeconds.count > 5 ? (s.zoneSeconds[4] + s.zoneSeconds[5]) / total : 0
            let mid = s.zoneSeconds.count > 5 ? s.zoneSeconds[3] / total : 0
            let intensity: FitnessAgeCalculator.Intensity
            if s.heartRate.isEmpty {
                switch s.activity {
                case .hiit, .run: intensity = .breathless
                case .yoga, .walk: intensity = .easy
                default: intensity = .breathless
                }
            } else {
                intensity = hard >= 0.25 ? .exhausted : (hard + mid) >= 0.2 ? .breathless : .easy
            }
            return .init(minutes: s.activeSeconds / 60, intensity: intensity)
        }
        let recordedDays = Set(monthSessions.map { cal.startOfDay(for: $0.start) })
        for r in lastMonth where !recordedDays.contains(cal.startOfDay(for: r.date)) {
            guard let a = r.activityStrain, a > 0 else { continue }
            let intensity: FitnessAgeCalculator.Intensity = a >= 13 ? .exhausted : a >= 8 ? .breathless : .easy
            list.append(.init(minutes: 45, intensity: intensity))
        }
        let activity = FitnessAgeCalculator.activityIndex(sessions: list)
        let s = AppSettings.shared
        let result = FitnessAgeCalculator.compute(age: s.age, sex: s.biologicalSex,
                                                  restingHRs: rhrs, activity: activity)

        // Other factors (last 7 days).
        let sleeps = lastWeek.compactMap(\.totalSleepMin).filter { $0 >= 180 }
        let bedtimes = lastWeek.compactMap(\.sleepOnset).map { d -> Double in
            let h = Double(cal.component(.hour, from: d)) + Double(cal.component(.minute, from: d)) / 60
            return h < 12 ? h + 24 : h
        }
        let weekSessions = sessions.filter { $0.start >= weekStart && $0.start < endOfEndDay }
        let moderate = weekSessions.reduce(0) { $0 + ($1.zoneSeconds.count > 3 ? $1.zoneSeconds[2] + $1.zoneSeconds[3] : 0) } / 60
        let vigorous = weekSessions.reduce(0) { $0 + ($1.zoneSeconds.count > 5 ? $1.zoneSeconds[4] + $1.zoneSeconds[5] : 0) } / 60

        return Snapshot(result: result, rhrNights: rhrs.count,
                        avgSleepMin: sleeps.isEmpty ? nil : Stats.mean(sleeps),
                        bedtimeSDHours: bedtimes.count >= 3 ? Stats.stdDev(bedtimes) : nil,
                        moderateMinutes: moderate, vigorousMinutes: vigorous,
                        recordedWorkouts: monthSessions.count)
    }

    /// Fitness Age at weekly points, oldest first.
    static func trend(records: [DailyRecord], sessions: [ExerciseSession], weeks: Int = 8) -> [(Date, Double)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<weeks).reversed().compactMap { w in
            let end = cal.date(byAdding: .day, value: -7 * w, to: today)!
            return snapshot(at: end, records: records, sessions: sessions).result.map { (end, $0.fitnessAge) }
        }
    }
}

// MARK: - Card (Perform tab)

struct FitnessAgeCard: View {
    @Query(sort: \DailyRecord.date, order: .reverse) private var records: [DailyRecord]
    @State private var store = ExerciseStore.shared

    var body: some View {
        let snap = FitnessAgeInputs.snapshot(at: Date(), records: records, sessions: store.sessions)
        NavigationLink {
            FitnessAgeDetailView()
        } label: {
            SectionCard(title: "Fitness age", systemImage: "figure.walk.motion") {
                if let r = snap.result {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(r.isAtFloor ? "≤\(Int(FitnessAgeCalculator.floorAge))" : "\(Int(r.fitnessAge.rounded()))")
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .foregroundStyle(FitnessAgeDetailView.color(r.difference))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(FitnessAgeDetailView.headline(r)).font(.subheadline.weight(.semibold))
                            Text("Likely range \(Int(r.low.rounded()))–\(Int(r.high.rounded())) · you're \(r.age)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Not enough data yet").font(.headline).foregroundStyle(.secondary)
                            Text("Needs resting heart rate from \(FitnessAgeCalculator.minRHRNights) of the last 7 nights (\(snap.rhrNights) so far).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Detail

struct FitnessAgeDetailView: View {
    @Query(sort: \DailyRecord.date, order: .reverse) private var records: [DailyRecord]
    @State private var store = ExerciseStore.shared

    var body: some View {
        let snap = FitnessAgeInputs.snapshot(at: Date(), records: records, sessions: store.sessions)
        let trend = FitnessAgeInputs.trend(records: records, sessions: store.sessions)
        ScrollView {
            VStack(spacing: 16) {
                if let r = snap.result {
                    header(r)
                    driversCard(r, snap: snap)
                    if trend.count >= 2 { trendCard(trend, age: r.age) }
                } else {
                    EmptyStateView(title: "Not enough data yet",
                                   message: "Fitness age needs your resting heart rate from at least \(FitnessAgeCalculator.minRHRNights) of the last 7 nights (\(snap.rhrNights) so far). Wear your band to sleep or sync Apple Health.",
                                   systemImage: "figure.walk.motion")
                        .frame(minHeight: 260)
                }
                otherFactorsCard(snap)
                methodCard
            }
            .padding()
        }
        .navigationTitle("Fitness age")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Sections

    private func header(_ r: FitnessAgeCalculator.Result) -> some View {
        VStack(spacing: 6) {
            Text(r.isAtFloor ? "≤\(Int(FitnessAgeCalculator.floorAge))" : "\(Int(r.fitnessAge.rounded()))")
                .font(.system(size: 80, weight: .heavy, design: .rounded))
                .foregroundStyle(Self.color(r.difference))
            Text(Self.headline(r)).font(.headline)
            Text("Likely range \(Int(r.low.rounded()))–\(Int(r.high.rounded())) · your age \(r.age)")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("How your cardio fitness compares with the typical person, in years. Not a medical or biological age.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    private func driversCard(_ r: FitnessAgeCalculator.Result, snap: FitnessAgeInputs.Snapshot) -> some View {
        SectionCard(title: "What's moving it", systemImage: "slider.horizontal.3") {
            driverRow(icon: "heart.fill", title: "Resting heart rate",
                      detail: "\(Int(r.restingHR.rounded())) bpm (median of \(snap.rhrNights) nights) vs a typical \(Int(FitnessAgeCalculator.referenceRHR))",
                      years: r.rhrYears)
            Divider()
            driverRow(icon: "figure.run", title: "Training",
                      detail: r.activity.summary.prefix(1).uppercased() + r.activity.summary.dropFirst()
                        + " (last 4 weeks)",
                      years: r.activityYears)
            Text(tip(r)).font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            if snap.recordedWorkouts == 0 && r.activity.sessionsPerWeek == 0 {
                Text("No workouts found in the last 4 weeks. If you train without recording it, your fitness age will read older than it is. Record workouts in the Exercise tab.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func driverRow(icon: String, title: String, detail: String, years: Double) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(format: "%+.1f yrs", years))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(years <= 0 ? Color.opGreen : Color.opRed)
        }
    }

    private func trendCard(_ points: [(Date, Double)], age: Int) -> some View {
        SectionCard(title: "Last \(points.count) weeks", systemImage: "chart.line.uptrend.xyaxis") {
            Chart {
                RuleMark(y: .value("Your age", age))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("your age").font(.caption2).foregroundStyle(.secondary)
                    }
                ForEach(points, id: \.0) { p in
                    LineMark(x: .value("Week", p.0), y: .value("Fitness age", p.1))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Week", p.0), y: .value("Fitness age", p.1))
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 160)
        }
    }

    private func otherFactorsCard(_ snap: FitnessAgeInputs.Snapshot) -> some View {
        SectionCard(title: "Other long-term health factors", systemImage: "leaf.fill") {
            factorRow("Sleep duration",
                      value: snap.avgSleepMin.map { "\(Int($0) / 60)h \(String(format: "%02d", Int($0) % 60))m avg" } ?? "No data",
                      target: "7–9 h",
                      status: snap.avgSleepMin.map(FitnessAgeCalculator.sleepDurationStatus))
            Divider()
            factorRow("Sleep consistency",
                      value: snap.bedtimeSDHours.map { "bedtime varies ±\(Int(($0 * 60).rounded())) min" } ?? "No data",
                      target: "within ±30 min",
                      status: snap.bedtimeSDHours.map(FitnessAgeCalculator.sleepConsistencyStatus))
            Divider()
            factorRow("Weekly activity",
                      value: "\(Int(snap.moderateMinutes)) min moderate · \(Int(snap.vigorousMinutes)) min vigorous",
                      target: "150 min moderate or 75 vigorous",
                      status: FitnessAgeCalculator.activityMinutesStatus(moderate: snap.moderateMinutes,
                                                                         vigorous: snap.vigorousMinutes))
            Text("These don't change the number above, but they're linked to long-term health. Activity minutes come from workouts recorded in the Exercise tab (zones 2–3 moderate, 4–5 vigorous).")
                .font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
        }
    }

    private func factorRow(_ title: String, value: String, target: String,
                           status: FitnessAgeCalculator.FactorStatus?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(status)).foregroundStyle(color(status)).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(value).font(.caption)
                Text("Target: \(target)").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var methodCard: some View {
        SectionCard(title: "How it's calculated", systemImage: "book.closed") {
            Text("Based on the HUNT fitness study's non-exercise VO₂ max model (Nes et al., 2011), the method behind NTNU's Fitness Age. It estimates your fitness from your age, sex, resting heart rate and how often, how long and how hard you exercise, then finds the age at which a typical person (resting HR \(Int(FitnessAgeCalculator.referenceRHR)) bpm, training 2–3 times a week) would have the same fitness.")
                .font(.caption)
            Text("Resting heart rate uses the median of your last 7 nights, and training uses your last 4 weeks of recorded workouts and activity strain. Resting HR measured during sleep is usually a little lower than a seated measurement, which can make the result read slightly younger. The model's error is about ±5 years, so watch the trend rather than single values. Not medical advice.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Helpers

    static func headline(_ r: FitnessAgeCalculator.Result) -> String {
        let d = r.difference
        if r.isAtFloor, d < 0 { return "\(Int((-d).rounded()))+ years younger than your age" }
        switch d {
        case ..<(-1.5): return "\(Int((-d).rounded())) years younger than your age"
        case 1.5...:    return "\(Int(d.rounded())) years older than your age"
        default:        return "About the same as your age"
        }
    }

    static func color(_ difference: Double) -> Color {
        difference <= -1.5 ? .opGreen : difference >= 1.5 ? .opRed : .opYellow
    }

    private func tip(_ r: FitnessAgeCalculator.Result) -> String {
        if r.activity.value < FitnessAgeCalculator.referencePA {
            return "Biggest lever: train more often. Moving from 1 to 2–3 sessions a week that get you out of breath lowers your fitness age by several years over time."
        }
        if r.restingHR > FitnessAgeCalculator.referenceRHR {
            return "Your resting HR is above typical. Regular aerobic training, good sleep and less alcohol tend to bring it down over weeks."
        }
        return "You're doing well. Keep a mix of steady aerobic sessions and some hard intervals to hold or improve it."
    }

    private func icon(_ s: FitnessAgeCalculator.FactorStatus?) -> String {
        switch s {
        case .good: return "checkmark.circle.fill"
        case .okay: return "minus.circle.fill"
        case .needsWork: return "exclamationmark.circle.fill"
        case nil: return "circle.dashed"
        }
    }

    private func color(_ s: FitnessAgeCalculator.FactorStatus?) -> Color {
        switch s {
        case .good: return .opGreen
        case .okay: return .opYellow
        case .needsWork: return .opRed
        case nil: return .secondary
        }
    }
}
