//
//  BodyView.swift
//  OutPerform
//
//  Stress monitor, health monitor (5 vitals vs baseline), illness heuristic
//  and VO₂ max
//

import SwiftUI
import SwiftData

struct BodyView: View {
    @Environment(AppSettings.self) private var settings
    @Query(sort: \DailyRecord.date, order: .reverse) private var records: [DailyRecord]
    private var latest: DailyRecord? { records.first { $0.recovery != nil } ?? records.first }

    var body: some View {
        // No NavigationStack here — this view is hosted inside the More tab's stack.
        ScrollView {
                VStack(spacing: 16) {
                    NavigationLink { AllMetricsView() } label: {
                        HStack {
                            Image(systemName: "square.grid.2x2.fill").foregroundStyle(.tint)
                            Text("All metrics").font(.headline)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(14)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)

                    if let r = latest {
                        stress(r)
                        healthMonitor(r)
                        vo2(r)
                    } else {
                        EmptyStateView(title: "Nothing to show yet",
                                       message: "Stress, health monitor and VO₂ max appear after syncing.",
                                       systemImage: "heart.text.square")
                            .frame(minHeight: 320)
                    }
                }
                .padding()
            }
            .navigationTitle("Body")
    }

    private func stress(_ r: DailyRecord) -> some View {
        SectionCard(title: "Stress monitor", systemImage: "waveform.path") {
            HStack {
                NavigationLink { MetricDetailView(kind: .stress) } label: {
                    ScoreRing(progress: (r.stress ?? 0)/100,
                              color: stressColor(r.stress), lineWidth: 10, size: 96,
                              title: "Stress", value: r.stress == nil ? "—" : Fmt.score(r.stress), caption: nil)
                }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 8) {
                    Text(r.stress == nil ? "Not enough data" : stressLabel(r.stress)).font(.headline)
                        .foregroundStyle(r.stress == nil ? .secondary : .primary)
                    Text(r.stress == nil
                         ? "Needs ~14 nights of HRV/HR baseline before stress is reliable."
                         : "From HRV/HR vs your 14-day baseline. Workout periods are excluded so strain isn't misread as stress.")
                        .font(.caption).foregroundStyle(.secondary)
                    NavigationLink {
                        BreathworkView()
                    } label: {
                        Label("Breathwork", systemImage: "wind").font(.subheadline.weight(.medium))
                    }.buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
        }
    }

    private func healthMonitor(_ r: DailyRecord) -> some View {
        let statuses = vitalStatuses()
        let illness = HealthMonitor.illnessAssessment(statuses)
        return SectionCard(title: "Health monitor", systemImage: "cross.case.fill") {
            if let msg = illness.message {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.opRed)
                    Text(msg).font(.caption)
                }
                .padding(10)
                .background(Color.opRed.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
            if statuses.isEmpty {
                Text("Not enough data — needs ~14 nights to calibrate baselines.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(statuses) { s in
                NavigationLink { MetricDetailView(kind: metricKind(for: s.metric)) } label: {
                    HStack {
                        Circle().fill(s.level.color).frame(width: 10, height: 10)
                        Text(s.metric.displayName).foregroundStyle(.primary)
                        Spacer()
                        Text(vitalValueString(s)).foregroundStyle(.secondary)
                        Text(String(format: "%+.1fσ", s.deviationStd))
                            .font(.caption).foregroundStyle(s.level.color)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .font(.subheadline)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    private func vo2(_ r: DailyRecord) -> some View {
        NavigationLink { MetricDetailView(kind: .vo2Max) } label: {
            SectionCard(title: "VO₂ max", systemImage: "lungs.fill") {
                if let v = r.vo2Max {
                    let level = VO2MaxCalculator.classify(vo2: v, sex: settings.biologicalSex)
                    HStack {
                        Text(String(format: "%.0f", v)).font(.largeTitle.bold())
                        Text("mL/kg·min").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Pill(text: level.displayName, color: vo2Color(level))
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    Text("The single best predictor of longevity. Tap for history & details.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("Not enough data").font(.headline).foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    Text("No VO₂ max from Apple Health yet, and no resting-HR estimate available.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.buttonStyle(.plain)
    }

    private func metricKind(for v: VitalMetric) -> MetricKind {
        switch v {
        case .heartRate: return .restingHR
        case .hrv: return .hrv
        case .respiratoryRate: return .respiratoryRate
        case .spo2: return .spo2
        case .skinTemp: return .skinTemp
        }
    }

    // MARK: Baselines

    private func vitalStatuses() -> [VitalStatus] {
        guard records.count > 14, let today = latest else { return [] }
        let history = Array(records.dropFirst().prefix(14))   // exclude today
        func baseline(_ key: KeyPath<DailyRecord, Double?>) -> Baseline? {
            let vals = history.compactMap { $0[keyPath: key] }
            // Needs a full 14-night baseline before deviation alerts are reliable.
            return vals.count >= 14 ? Baseline(values: vals) : nil
        }
        var out: [VitalStatus] = []
        if let v = today.restingHR, let b = baseline(\.restingHR) {
            out.append(HealthMonitor.status(metric: .heartRate, value: v, baseline: b)) }
        if let v = today.hrv, let b = baseline(\.hrv) {
            out.append(HealthMonitor.status(metric: .hrv, value: v, baseline: b)) }
        if let v = today.respiratoryRate, let b = baseline(\.respiratoryRate) {
            out.append(HealthMonitor.status(metric: .respiratoryRate, value: v, baseline: b)) }
        if let v = today.spo2Avg, let b = baseline(\.spo2Avg) {
            out.append(HealthMonitor.status(metric: .spo2, value: v, baseline: b)) }
        if let v = today.skinTempC, let b = baseline(\.skinTempC) {
            out.append(HealthMonitor.status(metric: .skinTemp, value: v, baseline: b)) }
        return out
    }

    private func vitalValueString(_ s: VitalStatus) -> String {
        switch s.metric {
        case .heartRate: return "\(Int(s.value)) bpm"
        case .hrv: return "\(Int(s.value)) ms"
        case .respiratoryRate: return Fmt.decimal(s.value, 1)
        case .spo2: return Fmt.pct(s.value)
        case .skinTemp: return String(format: "%.1f°C", s.value)
        }
    }

    private func stressColor(_ s: Double?) -> Color {
        guard let s else { return .gray }
        return s < 34 ? .opGreen : (s < 67 ? .opYellow : .opRed)
    }
    private func stressLabel(_ s: Double?) -> String {
        guard let s else { return "—" }
        return s < 34 ? "Calm" : (s < 67 ? "Moderate" : "Elevated")
    }
    private func vo2Color(_ l: FitnessLevel) -> Color {
        switch l { case .elite: return .opGreen; case .good: return .opGreen
        case .average: return .opYellow; case .poor: return .opRed }
    }
}
