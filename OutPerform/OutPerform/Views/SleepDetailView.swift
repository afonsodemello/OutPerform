//
//  SleepDetailView.swift
//  OutPerform
//
//  Sleep performance, stage breakdown, sleep need / bedtime planner and the
//  apnea screening result
//

import SwiftUI
import SwiftData
import Charts

struct SleepDetailView: View {
    @Environment(AppSettings.self) private var settings
    @Query(sort: \DailyRecord.date, order: .reverse) private var records: [DailyRecord]
    private var latest: DailyRecord? { records.first { ($0.totalSleepMin ?? 0) > 0 } ?? records.first }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let r = latest, (r.totalSleepMin ?? 0) > 0 {
                        NavigationLink { MetricDetailView(kind: .sleepPerformance) } label: {
                            ScoreRing(progress: (r.sleepPerformance ?? 0)/100, color: .opPurple,
                                      lineWidth: 16, size: 170, title: "Sleep",
                                      value: Fmt.pct(r.sleepPerformance), caption: Fmt.minutes(r.totalSleepMin))
                        }.buttonStyle(.plain)
                        stages(r)
                        stageTiles(r)
                        metrics(r)
                        wakeTimePicker
                        planner(r)
                        apnea(r)
                        sleepDebtInfo
                        scienceLink
                    } else {
                        EmptyStateView(title: "No sleep data",
                                       message: "Once a night of sleep is synced, you'll see stages, performance and your bedtime plan here.",
                                       systemImage: "bed.double")
                            .frame(minHeight: 360)
                    }
                }
                .padding()
            }
            .navigationTitle("Sleep")
        }
    }

    private func stages(_ r: DailyRecord) -> some View {
        SectionCard(title: "Stages", systemImage: "chart.bar.fill") {
            Chart {
                stageBar("Deep", r.deepMin, .indigo)
                stageBar("REM", r.remMin, .opPurple)
                stageBar("Light", r.coreMin, .opBlue)
                stageBar("Awake", r.awakeMin, .gray)
            }
            .chartXAxisLabel("minutes")
            .frame(height: 150)
            HStack {
                legend("Restorative", Fmt.pct(r.restorativePct), .opPurple)
                Spacer()
                legend("Efficiency", Fmt.pct(r.sleepEfficiency), .opGreen)
                Spacer()
                legend("Wake events", "\(r.wakeEvents ?? 0)", .gray)
            }.font(.caption)
        }
    }

    private func stageBar(_ name: String, _ min: Double?, _ color: Color) -> some ChartContent {
        BarMark(x: .value("min", min ?? 0), y: .value("stage", name))
            .foregroundStyle(color)
    }

    private func stageTiles(_ r: DailyRecord) -> some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, spacing: 12) {
            MetricLinkTile(kind: .remSleep, record: r)
            MetricLinkTile(kind: .deepSleep, record: r)
            MetricLinkTile(kind: .lightSleep, record: r)
            MetricLinkTile(kind: .restorative, record: r)
            MetricLinkTile(kind: .sleepEfficiency, record: r)
            MetricLinkTile(kind: .totalSleep, record: r)
        }
    }

    private func legend(_ t: String, _ v: String, _ c: Color) -> some View {
        VStack { Text(v).font(.subheadline.bold()).foregroundStyle(c); Text(t).foregroundStyle(.secondary) }
    }

    private func metrics(_ r: DailyRecord) -> some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, spacing: 12) {
            MetricLinkTile(kind: .totalSleep, record: r)
            MetricTile(name: "In bed", value: Fmt.minutes(r.timeInBedMin), systemImage: "bed.double", tint: .opBlue)
            MetricTile(name: "Onset", value: Fmt.time(r.sleepOnset), systemImage: "moon.fill", tint: .indigo)
            MetricTile(name: "Wake", value: Fmt.time(r.sleepWake), systemImage: "sunrise.fill", tint: .opYellow)
        }
    }

    private var wakeTimePicker: some View {
        SectionCard(title: "Wake time", systemImage: "alarm") {
            DatePicker("Target wake time",
                       selection: Binding(
                           get: { Calendar.current.date(bySettingHour: settings.wakeMinuteOfDay / 60,
                                                        minute: settings.wakeMinuteOfDay % 60,
                                                        second: 0, of: Date())! },
                           set: { d in
                               let c = Calendar.current
                               settings.wakeMinuteOfDay = c.component(.hour, from: d) * 60
                                   + c.component(.minute, from: d)
                           }),
                       displayedComponents: .hourAndMinute)
            Text("Used to calculate your suggested bedtime and focus windows.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func planner(_ r: DailyRecord) -> some View {
        let need = r.sleepNeedMin ?? 480
        let bedtime = SleepNeedCalculator.bedtime(
            desiredWake: settings.desiredWakeDate(),
            needMinutes: need, target: settings.performanceTarget,
            sleepLatencyMin: settings.sleepLatencyMin)
        return NavigationLink { MetricDetailView(kind: .sleepNeed) } label: {
            SectionCard(title: "Sleep need & bedtime", systemImage: "alarm.fill") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Need tonight").font(.caption).foregroundStyle(.secondary)
                        Text(r.sleepNeedMin == nil ? "Not enough data" : Fmt.minutes(need)).font(.title2.bold())
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("Suggested bedtime").font(.caption).foregroundStyle(.secondary)
                        Text(Fmt.time(bedtime)).font(.title2.bold()).foregroundStyle(.opPurple)
                    }
                }
                if let debt = r.sleepDebtMin, debt > 10 {
                    Pill(text: "Sleep debt: \(Fmt.minutes(debt))", color: .opYellow)
                }
                Text("Based on a dynamic sleep-need model (baseline + strain + debt). It rises through the day as today's strain builds up. Target: \(settings.performanceTarget.displayName). Tap for details.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.buttonStyle(.plain)
    }

    private func apnea(_ r: DailyRecord) -> some View {
        NavigationLink { MetricDetailView(kind: .odi) } label: {
            SectionCard(title: "Sleep apnea screening", systemImage: "stethoscope") {
                if let odi = r.odi {
                    let risk = ApneaRisk(odi: odi)
                    HStack {
                        Text(String(format: "ODI %.1f", odi)).font(.title3.bold())
                        Spacer()
                        Pill(text: risk.label, color: risk == .normal ? .opGreen : .opYellow)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                } else {
                    HStack {
                        Text("Not enough data").font(.headline).foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    Text("Needs overnight blood-oxygen readings to screen.").font(.caption2).foregroundStyle(.secondary)
                }
                Text("Screening only — not a diagnosis. If consistently elevated, consider a sleep study.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.buttonStyle(.plain)
    }

    /// How accurate is sleep debt / sleep need over time.
    private var nights: Int { records.filter { ($0.totalSleepMin ?? 0) >= 180 }.count }

    private var sleepDebtInfo: some View {
        SectionCard(title: "How sleep debt & need calibrate", systemImage: "hourglass") {
            Text("Tracked nights so far: \(nights)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(nights >= 14 ? .opGreen : .opYellow)

            Text("Your sleep need (and the sleep debt measured against it) is built from your personal baseline — the average sleep on your low-strain nights. Until that baseline forms, the app uses a generic 8-hour target, so early numbers are rough.")
                .font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                debtRow("1–3 nights", "A number appears, but it's measured against the default 8 h — treat it as a placeholder.")
                debtRow("~7 nights", "Directionally useful — it starts reflecting your real under/over-sleeping.")
                debtRow("~14 nights", "Reliable — the baseline is genuinely \u{2018}you\u{2019} by now.")
                debtRow("~30 nights", "Fully settled — built from a rolling 30-day window of your low-strain nights.")
            }

            Text("Only real tracked nights (≥3 h) count; missing nights are skipped, not charged as debt. Debt is capped at 3 hours and decays as you catch up, so it self-corrects rather than piling up.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func debtRow(_ when: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(when).font(.caption.weight(.semibold)).frame(width: 78, alignment: .leading)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var scienceLink: some View {
        Link(destination: URL(string: "https://outperform.afonsodemello.com/science.html")!) {
            HStack(spacing: 10) {
                Image(systemName: "book.pages")
                    .font(.body).foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Science & Sources").font(.subheadline.weight(.semibold))
                    Text("Peer-reviewed citations for every sleep calculation in this app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
