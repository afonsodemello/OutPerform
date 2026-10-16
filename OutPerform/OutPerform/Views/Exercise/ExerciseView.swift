//
//  ExerciseView.swift
//  OutPerform
//
//  The Exercise tab: start a workout, see today's strain and training load,
//  and browse recorded workouts.
//

import SwiftUI

struct ExerciseView: View {
    @Environment(AppModel.self) private var appModel
    @State private var recorder = WorkoutRecorder.shared
    @State private var store = ExerciseStore.shared
    @State private var band = BandManager.shared
    @State private var activity: ExerciseActivity = .run
    @State private var useGPS = true
    @State private var showLive = false
    @State private var showStrainDetails = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    startCard
                    if !store.sessions.isEmpty { historyCard }
                    StrainContent(showsEmptyState: false)
                }
                .padding()
            }
            .navigationTitle("Exercise")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { ZoneSettingsView() } label: { Image(systemName: "heart.text.square") }
                        .accessibilityLabel("Heart-rate zones")
                }
            }
            .fullScreenCover(isPresented: $showLive) { LiveWorkoutView() }
            .onAppear { if recorder.isActive { showLive = true } }
        }
    }

    // MARK: Start

    private var startCard: some View {
        SectionCard(title: recorder.isActive ? "Workout in progress" : "Start a workout",
                    systemImage: "figure.run.circle.fill") {
            if recorder.isActive {
                Button { showLive = true } label: {
                    Label("Return to \(recorder.activity.displayName.lowercased())", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(ExerciseActivity.allCases) { a in
                        Button {
                            activity = a
                            useGPS = a.usesGPSByDefault
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: a.systemImage).font(.title3)
                                Text(a.displayName).font(.caption2)
                            }
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(activity == a ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .stroke(activity == a ? Color.accentColor : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Toggle(isOn: $useGPS) {
                    Label("GPS (distance, pace, route)", systemImage: "location.fill")
                }
                .font(.subheadline)
                heartRateStatus
                Button {
                    recorder.start(activity: activity, useGPS: useGPS,
                                   restingHR: appModel.engine.latestRecord()?.restingHR)
                    showLive = true
                } label: {
                    Label("Start \(activity.displayName.lowercased())", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
    }

    @ViewBuilder private var heartRateStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: band.liveBPM != nil ? "heart.fill" : "heart.slash")
                .foregroundStyle(band.liveBPM != nil ? .red : .secondary)
            if let bpm = band.liveBPM {
                Text("\(band.pairedName ?? "Band") · \(bpm) bpm").font(.subheadline)
            } else if band.isPaired {
                Text("\(band.pairedName ?? "Band"): \(band.state.label.lowercased()). The workout still records GPS and motion; heart rate joins when the band connects.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                NavigationLink { BandView() } label: {
                    Text("Pair your band to see live heart rate and zones").font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: History

    private var historyCard: some View {
        SectionCard(title: "Workouts", systemImage: "list.bullet") {
            ForEach(store.sessions.prefix(10)) { s in
                NavigationLink { WorkoutDetailView(session: s) } label: { WorkoutRow(session: s) }
                    .buttonStyle(.plain)
                if s.id != store.sessions.prefix(10).last?.id { Divider() }
            }
        }
    }
}

struct WorkoutRow: View {
    let session: ExerciseSession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.activity.systemImage)
                .font(.title3).frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(session.activity.displayName).font(.subheadline.weight(.semibold))
                Text(session.start.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(WorkoutFormat.duration(session.activeSeconds)).font(.subheadline.monospacedDigit())
                Text([session.distanceMeters.map(WorkoutFormat.distance), session.avgHR.map { "\($0) bpm" }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

enum WorkoutFormat {
    static func duration(_ s: Double) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }

    static func distance(_ m: Double) -> String {
        m >= 1000 ? String(format: "%.2f km", m / 1000) : String(format: "%.0f m", m)
    }

    /// min:sec per km from m/s.
    static func pace(_ speed: Double?) -> String {
        guard let v = speed, v > 0.3 else { return "–" }
        let secPerKm = 1000 / v
        guard secPerKm < 60 * 60 else { return "–" }
        return String(format: "%d:%02d /km", Int(secPerKm) / 60, Int(secPerKm) % 60)
    }

    static func speed(_ speed: Double?) -> String {
        guard let v = speed, v >= 0 else { return "–" }
        return String(format: "%.1f km/h", v * 3.6)
    }
}
