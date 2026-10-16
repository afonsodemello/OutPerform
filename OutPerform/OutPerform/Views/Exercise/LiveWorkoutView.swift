//
//  LiveWorkoutView.swift
//  OutPerform
//
//  The full-screen live view while a workout is recording: heart rate and
//  zone, time, and whichever movement metrics make sense for the activity.
//

import SwiftUI
import MapKit

struct LiveWorkoutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var appModel
    @State private var recorder = WorkoutRecorder.shared
    @State private var band = BandManager.shared
    @State private var confirmEnd = false
    @State private var finished: ExerciseSession?
    @State private var showMap = true

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ScrollView {
                    VStack(spacing: 14) {
                        header(now: context.date)
                        heartRateCard
                        zoneBar
                        metricsGrid(now: context.date)
                        if recorder.usesGPS { mapCard }
                        if recorder.locationDenied {
                            Label("Location access is off, so there's no GPS distance or route. Turn it on in Settings → OutPerform → Location.",
                                  systemImage: "location.slash")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .padding()
                }
            }
            .safeAreaInset(edge: .bottom) { controls }
            .navigationTitle(recorder.activity.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "chevron.down") }
                        .accessibilityLabel("Minimise")
                }
            }
            .confirmationDialog("End workout?", isPresented: $confirmEnd, titleVisibility: .visible) {
                Button("Save workout") {
                    finished = recorder.finish()
                    if finished == nil { dismiss() }
                    else { Task { await appModel.refresh() } }   // count it toward today's strain
                }
                Button("Discard", role: .destructive) { recorder.discard(); dismiss() }
            } message: {
                Text("Workouts under 30 seconds aren't saved.")
            }
            .sheet(item: $finished, onDismiss: { dismiss() }) { session in
                NavigationStack {
                    WorkoutDetailView(session: session)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { finished = nil } } }
                }
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    // MARK: Sections

    private func header(now: Date) -> some View {
        VStack(spacing: 2) {
            Text(WorkoutFormat.duration(recorder.activeSeconds(at: now)))
                .font(.system(size: 56, weight: .bold, design: .rounded).monospacedDigit())
            Text(recorder.state == .paused ? "Paused" : "Moving time")
                .font(.caption).foregroundStyle(recorder.state == .paused ? .orange : .secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var heartRateCard: some View {
        let bpm = band.liveBPM ?? recorder.currentBPM
        let zone = bpm.map { ZoneSettings.shared.zone(for: $0) } ?? 0
        return HStack(alignment: .firstTextBaseline) {
            Image(systemName: "heart.fill").foregroundStyle(.red)
                .symbolEffect(.pulse, isActive: bpm != nil)
            Text(bpm.map(String.init) ?? "–")
                .font(.system(size: 64, weight: .heavy, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
            Text("bpm").foregroundStyle(.secondary)
            Spacer()
            if bpm != nil {
                VStack(alignment: .trailing) {
                    Text(zone > 0 ? "Zone \(zone)" : "Below zones").font(.headline)
                    Text(ZoneSettings.name(zone)).font(.caption)
                }
                .foregroundStyle(ZoneSettings.color(zone))
            } else {
                Text(band.isPaired ? band.state.label : "No band").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(ZoneSettings.color(zone).opacity(bpm == nil ? 0.05 : 0.15), in: RoundedRectangle(cornerRadius: 18))
    }

    private var zoneBar: some View {
        let total = max(1, recorder.zoneSeconds.reduce(0, +))
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(0..<6, id: \.self) { z in
                        let w = recorder.zoneSeconds[z] / total
                        if w > 0 {
                            ZoneSettings.color(z).opacity(z == 0 ? 0.4 : 1)
                                .frame(width: max(2, geo.size.width * w))
                        }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            HStack {
                ForEach(1...5, id: \.self) { z in
                    Text("Z\(z) \(WorkoutFormat.duration(recorder.zoneSeconds[z]))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(ZoneSettings.color(z))
                    if z < 5 { Spacer(minLength: 0) }
                }
            }
        }
    }

    private func metricsGrid(now: Date) -> some View {
        var tiles: [(String, String, String)] = []
        let a = recorder.activity
        let moving = recorder.activeSeconds(at: now)
        if recorder.usesGPS || (a.countsSteps && recorder.distance > 0) {
            tiles.append(("Distance", WorkoutFormat.distance(recorder.distance), "point.topleft.down.to.point.bottomright.curvepath"))
            if a.prefersPace {
                tiles.append(("Pace", WorkoutFormat.pace(recorder.currentSpeed), "speedometer"))
                tiles.append(("Avg pace", WorkoutFormat.pace(moving > 0 ? recorder.distance / moving : nil), "gauge.with.dots.needle.33percent"))
            } else {
                tiles.append(("Speed", WorkoutFormat.speed(recorder.currentSpeed), "speedometer"))
                tiles.append(("Avg speed", WorkoutFormat.speed(moving > 0 ? recorder.distance / moving : nil), "gauge.with.dots.needle.33percent"))
            }
        }
        if recorder.elevationGain > 0 || a.usesGPSByDefault {
            tiles.append(("Elevation gain", String(format: "%.0f m", recorder.elevationGain), "mountain.2.fill"))
        }
        if let steps = recorder.steps { tiles.append(("Steps", "\(steps)", "shoeprints.fill")) }
        if let c = recorder.cadence, a.countsSteps { tiles.append(("Cadence", String(format: "%.0f spm", c), "metronome.fill")) }
        if let f = recorder.floors, f > 0 { tiles.append(("Floors", "\(f)", "stairs")) }
        tiles.append(("Calories", String(format: "%.0f kcal", recorder.kcal), "flame.fill"))
        let hrs = recorder.heartRate.map(\.bpm)
        if !hrs.isEmpty {
            tiles.append(("Avg HR", "\(hrs.reduce(0, +) / hrs.count) bpm", "heart"))
            tiles.append(("Max HR", "\(hrs.max() ?? 0) bpm", "heart.circle"))
        }
        if let last = recorder.splits.last {
            tiles.append(("Last km", WorkoutFormat.duration(last), "flag.checkered"))
        }
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(tiles, id: \.0) { t in
                VStack(alignment: .leading, spacing: 4) {
                    Label(t.0, systemImage: t.2).font(.caption).foregroundStyle(.secondary)
                    Text(t.1).font(.title3.bold().monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var mapCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(gpsLabel, systemImage: "location.fill").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(showMap ? "Hide map" : "Show map") { showMap.toggle() }.font(.caption)
            }
            if showMap {
                Map(initialPosition: .userLocation(fallback: .automatic)) {
                    UserAnnotation()
                    if recorder.route.count > 1 {
                        MapPolyline(coordinates: recorder.route.map(\.coordinate))
                            .stroke(.orange, lineWidth: 4)
                    }
                }
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var gpsLabel: String {
        guard let acc = recorder.gpsAccuracy else { return "Waiting for GPS…" }
        return acc <= 10 ? "GPS strong" : acc <= 25 ? "GPS ok (±\(Int(acc)) m)" : "GPS weak (±\(Int(acc)) m)"
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if recorder.state == .running {
                Button { recorder.pause() } label: {
                    Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(.orange)
            } else {
                Button { recorder.resume() } label: {
                    Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.green)
            }
            Button { confirmEnd = true } label: {
                Label("End", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.red)
        }
        .controlSize(.large)
        .padding()
        .background(.ultraThinMaterial)
    }
}
