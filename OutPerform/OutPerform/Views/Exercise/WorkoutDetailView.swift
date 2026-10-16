//
//  WorkoutDetailView.swift
//  OutPerform
//
//  One recorded workout: summary, heart rate over time against your zones,
//  time in each zone, route and kilometre splits.
//

import SwiftUI
import Charts
import MapKit

struct WorkoutDetailView: View {
    let session: ExerciseSession
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    private let zones = ZoneSettings.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                summary
                if !session.heartRate.isEmpty {
                    heartRateChart
                    zoneBreakdown
                }
                if session.route.count > 1 { routeMap }
                if !session.splits.isEmpty { splitsCard }
                if session.recovered {
                    Label("Recovered after the app was closed during this workout.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Delete workout", role: .destructive) { confirmDelete = true }
                    .padding(.top, 8)
            }
            .padding()
        }
        .navigationTitle(session.activity.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this workout?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                ExerciseStore.shared.delete(session)
                dismiss()
            }
        }
    }

    private var summary: some View {
        var items: [(String, String)] = [("Time", WorkoutFormat.duration(session.activeSeconds))]
        if let d = session.distanceMeters { items.append(("Distance", WorkoutFormat.distance(d))) }
        if session.distanceMeters != nil {
            items.append(session.activity.prefersPace
                         ? ("Avg pace", WorkoutFormat.pace(session.avgSpeed))
                         : ("Avg speed", WorkoutFormat.speed(session.avgSpeed)))
        }
        if let a = session.avgHR { items.append(("Avg HR", "\(a) bpm")) }
        if let m = session.maxHR { items.append(("Max HR", "\(m) bpm")) }
        if let k = session.kcal { items.append(("Calories", String(format: "%.0f kcal", k))) }
        if let e = session.elevationGainMeters { items.append(("Elevation", String(format: "%.0f m", e))) }
        if let s = session.steps { items.append(("Steps", "\(s)")) }
        if let f = session.floorsAscended, f > 0 { items.append(("Floors", "\(f)")) }

        return SectionCard(title: session.start.formatted(date: .complete, time: .shortened),
                           systemImage: session.activity.systemImage) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                      alignment: .leading, spacing: 12) {
                ForEach(items, id: \.0) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.0).font(.caption).foregroundStyle(.secondary)
                        Text(item.1).font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
            }
            if let src = session.heartRateSource {
                Text("Heart rate from \(src)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var heartRateChart: some View {
        let bounds = zones.lowerBounds
        let hrs = session.heartRate.map(\.bpm)
        let lo = Double(min(hrs.min() ?? 60, bounds[0]) - 5), hi = Double(max(hrs.max() ?? 180, bounds[4]) + 5)
        return SectionCard(title: "Heart rate", systemImage: "waveform.path.ecg") {
            Chart {
                ForEach(1...5, id: \.self) { z in
                    RectangleMark(
                        yStart: .value("from", Double(bounds[z - 1])),
                        yEnd: .value("to", z == 5 ? hi : Double(bounds[z])))
                    .foregroundStyle(ZoneSettings.color(z).opacity(0.10))
                }
                ForEach(session.heartRate, id: \.t) { s in
                    LineMark(x: .value("Time", s.t), y: .value("bpm", s.bpm))
                        .foregroundStyle(.red)
                        .interpolationMethod(.monotone)
                }
            }
            .chartYScale(domain: lo...hi)
            .frame(height: 200)
        }
    }

    private var zoneBreakdown: some View {
        let total = max(1, session.zoneSeconds.reduce(0, +))
        return SectionCard(title: "Time in zones", systemImage: "chart.bar.fill") {
            ForEach((1...5).reversed(), id: \.self) { z in
                HStack(spacing: 8) {
                    Text("Z\(z)").font(.caption.bold()).foregroundStyle(ZoneSettings.color(z)).frame(width: 24)
                    GeometryReader { geo in
                        Capsule().fill(ZoneSettings.color(z))
                            .frame(width: max(2, geo.size.width * session.zoneSeconds[z] / total))
                    }
                    .frame(height: 10)
                    Text(WorkoutFormat.duration(session.zoneSeconds[z]))
                        .font(.caption.monospacedDigit()).frame(width: 56, alignment: .trailing)
                }
            }
            Text("Zones as set now: \((1...5).map { "Z\($0) \(zones.rangeText($0))" }.joined(separator: " · "))")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var routeMap: some View {
        SectionCard(title: "Route", systemImage: "map.fill") {
            Map(initialPosition: .automatic) {
                MapPolyline(coordinates: session.route.map(\.coordinate))
                    .stroke(.orange, lineWidth: 4)
                if let first = session.route.first {
                    Marker("Start", systemImage: "flag.fill", coordinate: first.coordinate).tint(.green)
                }
                if let last = session.route.last {
                    Marker("Finish", systemImage: "flag.checkered", coordinate: last.coordinate).tint(.red)
                }
            }
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private var splitsCard: some View {
        let fastest = session.splits.min() ?? 0
        return SectionCard(title: "Splits", systemImage: "flag.checkered") {
            ForEach(Array(session.splits.enumerated()), id: \.offset) { i, t in
                HStack {
                    Text("Km \(i + 1)").font(.subheadline)
                    Spacer()
                    Text(WorkoutFormat.duration(t)).font(.subheadline.monospacedDigit())
                        .foregroundStyle(t == fastest ? .green : .primary)
                }
            }
        }
    }
}
