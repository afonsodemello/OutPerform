//
//  MetricDetailView.swift
//  OutPerform
//
//  One screen that explains any metric: current value (or an honest
//  "Not enough data"), a scrubbable history chart, summary stats, the full
//  calculation, and links to related metrics.
//

import SwiftUI
import SwiftData

struct MetricDetailView: View {
    let kind: MetricKind
    @Environment(AppSettings.self) private var settings
    @Query(sort: \DailyRecord.date, order: .reverse) private var records: [DailyRecord]

    private var info: MetricInfo { kind.info }
    /// Nights of usable data collected (proxy: nights with an HRV reading).
    private var usableDays: Int { records.filter { $0.hrv != nil }.count }
    private var isCalibrating: Bool { usableDays < info.calibrationDays }

    private var history: [TrendPoint] {
        records.reversed().compactMap { r in
            info.value(r).map { TrendPoint(date: r.date, value: $0) }
        }
    }
    private var latest: TrendPoint? { history.last }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                googleHealthUnavailableBanner
                if !history.isEmpty { chartCard }
                if history.count >= 2 { statsCard }
                howCard
                if !info.related.isEmpty { relatedCard }
            }
            .padding()
        }
        .navigationTitle(info.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Google Health unavailability banner

    @ViewBuilder private var googleHealthUnavailableBanner: some View {
        if kind == .dfaAlpha1 && settings.dataSource == .googleHealth {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.opYellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not available with Google Health")
                        .font(.subheadline.weight(.semibold))
                    Text("DFA-α1 requires raw beat-to-beat RR intervals, which Google Health doesn't expose. Switch to Apple Health (Apple Watch required) to unlock this metric.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(Color.opYellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: Header (honest about missing/insufficient data)

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: info.systemImage)
                .font(.system(size: 34)).foregroundStyle(info.tint)
            if latest == nil {
                Text("No data").font(.title.bold()).foregroundStyle(.secondary)
                Text("Nothing has synced for this metric yet.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if isCalibrating {
                Text("Not enough data").font(.title2.bold()).foregroundStyle(.secondary)
                Text("Calibrating — \(usableDays) of \(info.calibrationDays) nights. This metric needs a personal baseline before it's reliable.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if let p = latest {
                Text(info.format(p.value) + (info.unit.isEmpty || info.format(p.value).contains(info.unit) ? "" : ""))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(info.color(for: p.value))
                Text(p.date.formatted(date: .complete, time: .omitted))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: Chart

    private var chartCard: some View {
        SectionCard(title: "History", systemImage: "chart.xyaxis.line") {
            if history.count >= 2 {
                InteractiveTrendChart(points: history, tint: info.tint,
                                      domain: info.domain, format: info.format)
            } else {
                Text("Not enough data to chart yet — needs at least two days.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Stats

    private var statsCard: some View {
        let vals = history.map(\.value)
        let last7 = history.suffix(7).map(\.value)
        return SectionCard(title: "Summary", systemImage: "sum") {
            HStack {
                stat("Average", info.format(Stats.mean(vals)))
                Divider()
                stat("7-day", info.format(Stats.mean(last7)))
                Divider()
                stat("Min", info.format(vals.min() ?? 0))
                Divider()
                stat("Max", info.format(vals.max() ?? 0))
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.weight(.semibold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    // MARK: How it works

    private var howCard: some View {
        SectionCard(title: "How it's calculated", systemImage: "questionmark.circle") {
            Text(info.howItWorks).font(.subheadline).foregroundStyle(.secondary)
            if info.calibrationDays > 0 {
                Pill(text: "Needs \(info.calibrationDays) nights to calibrate", color: .opYellow)
            }
        }
    }

    // MARK: Related

    private var relatedCard: some View {
        SectionCard(title: "Related", systemImage: "link") {
            ForEach(info.related) { rk in
                NavigationLink {
                    MetricDetailView(kind: rk)
                } label: {
                    HStack {
                        Image(systemName: rk.info.systemImage).foregroundStyle(rk.info.tint).frame(width: 24)
                        Text(rk.info.title)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A tappable tile that pushes the metric's detail screen. Drop-in replacement
/// for read-only metric tiles.
struct MetricLinkTile: View {
    let kind: MetricKind
    var record: DailyRecord?
    var subtitle: String?

    var body: some View {
        NavigationLink {
            MetricDetailView(kind: kind)
        } label: {
            let info = kind.info
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(info.title, systemImage: info.systemImage)
                        .font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                Text(record.map { info.valueString($0) } ?? "No data")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(info.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
