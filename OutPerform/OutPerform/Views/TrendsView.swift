//
//  TrendsView.swift
//  OutPerform
//
//  7/30/90-day trends for every metric — always free. Each chart is
//  scrubbable (drag to read any day) and taps through to full metric details.
//

import SwiftUI
import SwiftData

struct TrendsView: View {
    @Query(sort: \DailyRecord.date, order: .reverse) private var records: [DailyRecord]
    @State private var range = 30

    // Every metric the app tracks gets a scrubbable trend.
    private let kinds: [MetricKind] = MetricKind.allCases

    private var windowed: [DailyRecord] { Array(records.prefix(range).reversed()) }

    var body: some View {
        // No NavigationStack here — this view is hosted inside the More tab's stack.
        ScrollView {
                VStack(spacing: 16) {
                    if records.count < 2 {
                        EmptyStateView(title: "Trends build over time",
                                       message: "Not enough data yet — come back after a couple of days of syncing to see your trajectory.",
                                       systemImage: "chart.xyaxis.line")
                            .frame(minHeight: 320)
                    } else {
                        Picker("Range", selection: $range) {
                            Text("7d").tag(7); Text("30d").tag(30); Text("90d").tag(90)
                        }.pickerStyle(.segmented)

                        ForEach(kinds) { kind in trendCard(kind) }
                    }
                }
                .padding()
            }
            .navigationTitle("Trends")
    }

    private func trendCard(_ kind: MetricKind) -> some View {
        let info = kind.info
        let points = windowed.compactMap { r in
            info.value(r).map { TrendPoint(date: r.date, value: $0) }
        }
        return SectionCard(title: info.title, systemImage: info.systemImage) {
            NavigationLink { MetricDetailView(kind: kind) } label: {
                HStack {
                    Text("Tap for details").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)

            if points.count >= 2 {
                InteractiveTrendChart(points: points, tint: info.tint,
                                      domain: info.domain, format: info.format)
            } else {
                Text("Not enough data to chart yet.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
