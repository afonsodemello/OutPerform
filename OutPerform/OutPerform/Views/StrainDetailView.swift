//
//  StrainDetailView.swift
//  OutPerform
//
//  Day & activity strain, ACWR injury-risk and training monotony
//

import SwiftUI
import SwiftData
import Charts

struct StrainDetailView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                StrainContent().padding()
            }
            .navigationTitle("Strain")
        }
    }
}

/// Day strain, activity strain, ACWR, monotony and history. Shared by the
/// Strain screen and the Exercise tab.
struct StrainContent: View {
    @Query(sort: \DailyRecord.date, order: .reverse) private var records: [DailyRecord]
    private var latest: DailyRecord? { records.first { $0.dayStrain != nil } ?? records.first }
    /// The Exercise tab hides the big empty state under its own start card.
    var showsEmptyState = true

    var body: some View {
                VStack(spacing: 16) {
                    if let r = latest, let strain = r.dayStrain {
                        NavigationLink { MetricDetailView(kind: .strain) } label: {
                            ScoreRing(progress: strain/21, color: StrainZone(strain: strain).color,
                                      lineWidth: 16, size: 170, title: "Day strain",
                                      value: Fmt.strain(strain), caption: StrainZone(strain: strain).label)
                        }.buttonStyle(.plain)

                        if let act = r.activityStrain {
                            NavigationLink { MetricDetailView(kind: .activityStrain) } label: {
                                Pill(text: "Activity strain \(Fmt.strain(act))", color: .opBlue)
                            }.buttonStyle(.plain)
                        }

                        loadCard(title: "Injury-risk (ACWR)", kind: .acwr, value: r.acwr,
                                 format: { String(format: "%.2f", $0) },
                                 color: r.acwr.map { ACWRZone(ratio: $0).color } ?? .secondary,
                                 zoneLabel: r.acwr.map { ACWRZone(ratio: $0).label },
                                 needNote: "Needs ~14 nights of history.")

                        loadCard(title: "Training monotony", kind: .monotony, value: r.monotony,
                                 format: { String(format: "%.2f", $0) },
                                 color: (r.monotony ?? 0) > 2 ? .opYellow : .opGreen,
                                 zoneLabel: r.monotony.map { $0 > 2 ? "Add variety" : "Good variety" },
                                 needNote: "Needs 7 nights of history.")
                        history
                    } else if showsEmptyState {
                        EmptyStateView(title: "No strain data",
                                       message: "Strain accumulates from your heart rate across the day. It'll appear after your first synced day.",
                                       systemImage: "flame")
                            .frame(minHeight: 360)
                    }
                }
    }

    private func loadCard(title: String, kind: MetricKind, value: Double?,
                          format: (Double) -> String, color: Color,
                          zoneLabel: String?, needNote: String) -> some View {
        NavigationLink { MetricDetailView(kind: kind) } label: {
            SectionCard(title: title, systemImage: kind.info.systemImage) {
                if let v = value {
                    HStack {
                        Text(format(v)).font(.title.bold()).foregroundStyle(color)
                        Spacer()
                        if let zoneLabel { Pill(text: zoneLabel, color: color) }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                } else {
                    HStack {
                        Text("Not enough data").font(.headline).foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    Text(needNote).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.buttonStyle(.plain)
    }

    private var history: some View {
        NavigationLink { MetricDetailView(kind: .strain) } label: {
            SectionCard(title: "Last 14 days — tap to browse", systemImage: "chart.bar.fill") {
                MiniBarChart(points: records.prefix(14).reversed().map {
                    ($0.date, $0.dayStrain ?? 0)
                }, colorFor: { StrainZone(strain: $0).color })
            }
        }.buttonStyle(.plain)
    }
}

/// Small non-interactive bar overview (the scrubbable version lives in MetricDetailView).
struct MiniBarChart: View {
    let points: [(Date, Double)]
    var colorFor: (Double) -> Color
    var body: some View {
        Chart(points, id: \.0) { p in
            BarMark(x: .value("Day", p.0, unit: .day), y: .value("Value", p.1))
                .foregroundStyle(colorFor(p.1))
        }
        .frame(height: 150)
    }
}
