//
//  RecoveryDetailView.swift
//  OutPerform
//
//  Recovery score breakdown Every input is tappable.
//

import SwiftUI

struct RecoveryDetailView: View {
    let record: DailyRecord

    private let cols = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let rec = record.recovery {
                    ScoreRing(progress: rec / 100, color: RecoveryZone(score: rec).color,
                              lineWidth: 16, size: 180, title: "Recovery",
                              value: Fmt.pct(rec), caption: RecoveryZone(score: rec).label)
                } else {
                    EmptyStateView(title: "Not enough data",
                                   message: "Recovery needs last night's HRV and a forming baseline. It'll appear once data has synced.",
                                   systemImage: "arrow.clockwise.heart")
                        .frame(minHeight: 200)
                }

                SectionCard(title: "Inputs — tap any for details", systemImage: "list.bullet") {
                    LazyVGrid(columns: cols, spacing: 12) {
                        MetricLinkTile(kind: .hrv, record: record, subtitle: "Primary · 40% weight")
                        MetricLinkTile(kind: .restingHR, record: record, subtitle: "25% weight")
                        MetricLinkTile(kind: .respiratoryRate, record: record, subtitle: "10% weight")
                        MetricLinkTile(kind: .sleepPerformance, record: record, subtitle: "25% weight")
                        MetricLinkTile(kind: .skinTemp, record: record, subtitle: "Penalty if elevated")
                        MetricLinkTile(kind: .spo2, record: record, subtitle: "Penalty if low")
                        MetricLinkTile(kind: .dfaAlpha1, record: record, subtitle: "Nonlinear HRV")
                    }
                }

                NavigationLink { MetricDetailView(kind: .recovery) } label: {
                    Label("How recovery is calculated & full history", systemImage: "questionmark.circle")
                        .font(.subheadline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Text("Recovery is computed once each morning from the previous night and doesn't change during the day. Weights are adjustable in Settings → Advanced.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .navigationTitle("Recovery")
        .navigationBarTitleDisplayMode(.inline)
    }
}
