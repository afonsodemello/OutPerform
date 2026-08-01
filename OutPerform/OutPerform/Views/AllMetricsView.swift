//
//  AllMetricsView.swift
//  OutPerform
//
//  One place that lists every metric the app tracks, with its latest value,
//  each tappable through to full details. "All the data, in one list."
//

import SwiftUI
import SwiftData

struct AllMetricsView: View {
    @Query(sort: \DailyRecord.date, order: .reverse) private var records: [DailyRecord]

    private var latest: DailyRecord? { records.first { $0.hrv != nil || $0.totalSleepMin != nil } ?? records.first }
    private var usableDays: Int { records.filter { $0.hrv != nil }.count }

    private struct Group: Identifiable { let id = UUID(); let title: String; let kinds: [MetricKind] }

    private let groups: [Group] = [
        .init(title: "Daily scores", kinds: [.readiness, .recovery, .strain, .activityStrain, .sleepPerformance, .stress]),
        .init(title: "Heart", kinds: [.hrv, .dfaAlpha1, .restingHR, .vo2Max]),
        .init(title: "Respiration & blood", kinds: [.respiratoryRate, .spo2, .odi]),
        .init(title: "Body", kinds: [.skinTemp]),
        .init(title: "Sleep", kinds: [.totalSleep, .remSleep, .deepSleep, .lightSleep,
                                      .sleepEfficiency, .restorative, .sleepNeed, .sleepDebt]),
        .init(title: "Training load", kinds: [.acwr, .monotony])
    ]

    var body: some View {
        List {
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.kinds) { kind in row(kind) }
                }
            }
            Section {
                Text("Tap any metric for its formula, full history and a scrubbable chart. Values pulled from \(latest != nil ? "your latest sync" : "—").")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("All metrics")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func row(_ kind: MetricKind) -> some View {
        let info = kind.info
        let value = latest.flatMap { info.value($0) }
        let calibrating = value != nil && usableDays < info.calibrationDays
        NavigationLink {
            MetricDetailView(kind: kind)
        } label: {
            HStack {
                Image(systemName: info.systemImage).foregroundStyle(info.tint).frame(width: 26)
                Text(info.title)
                Spacer()
                if calibrating {
                    Text("\(usableDays)/\(info.calibrationDays)")
                        .font(.subheadline).foregroundStyle(.opYellow)
                } else if let v = value {
                    Text(info.format(v))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(info.color(for: v))
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
        }
    }
}
