//
//  BandView.swift
//  OutPerform
//
//  Pair, monitor and manage the Bluetooth band.
//

import SwiftUI

struct BandView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    /// Shown as a sheet at the end of onboarding: adds a "Done" button.
    var onDone: (() -> Void)? = nil

    @State private var band = BandManager.shared
    @State private var summary: StreamStore.Summary?
    @State private var confirmForget = false
    @State private var confirmDelete = false
    @State private var rescoring = false

    var body: some View {
        Form {
            statusSection
            if band.isPaired {
                pairedSection
            } else {
                searchSection
                setupHelpSection
            }
            recordingsSection
            Section {
                Text("Your band streams heart rate and beat-to-beat intervals to this iPhone. Sleep and its stages, resting HR, HRV, breathing rate, workouts, strain and recovery are all computed here from those two signals. Blood oxygen and skin temperature aren't part of the open Bluetooth heart-rate profile, so they stay empty. All scores are approximations, not medical measurements.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Band")
        .toolbar {
            if let onDone {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone(); dismiss() }
                }
            }
        }
        .task {
            await band.startWhenReady()
            await loadSummary()
        }
        .onDisappear { band.stopScan() }
        .confirmationDialog("Forget this band?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget band", role: .destructive) { band.forget() }
        } message: {
            Text("OutPerform stops connecting to it. Your recordings and scores are kept.")
        }
        .confirmationDialog("Delete all recordings?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete recordings", role: .destructive) {
                Task {
                    await StreamStore.shared.deleteAll()
                    await BandAnalysis.shared.clearCache()
                    await loadSummary()
                }
            }
        } message: {
            Text("This permanently deletes every heart-rate and heartbeat sample stored from the band. Scores already computed are kept.")
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    Circle().fill(statusColor.opacity(0.15)).frame(width: 64, height: 64)
                    Image(systemName: band.state == .connected ? "heart.fill" : "dot.radiowaves.left.and.right")
                        .font(.title)
                        .foregroundStyle(statusColor)
                        .symbolEffect(.pulse, isActive: band.state == .connected && band.liveBPM != nil)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(band.pairedName ?? "No band paired").font(.headline)
                    Text(band.isOffWrist ? "Off wrist" : band.state.label)
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let battery = band.batteryLevel {
                        Label("\(battery)%", systemImage: batteryIcon(battery))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let bpm = band.liveBPM {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(bpm)").font(.system(size: 40, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                        Text("bpm\(band.liveZone.flatMap { $0 > 0 ? " · Z\($0)" : nil } ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
            if band.state == .connected {
                LabeledContent("Heartbeat intervals", value: band.providesRR ? "Streaming" : "Not sent yet")
                if let rr = band.lastRRms {
                    LabeledContent("Last interval", value: "\(Int(rr)) ms")
                }
                LabeledContent("Recorded this session",
                               value: "\(band.samplesThisSession) HR · \(band.beatsThisSession) beats")
            }
            if band.state == .bluetoothOff {
                Text("Turn on Bluetooth in Control Center to connect.").font(.caption).foregroundStyle(.secondary)
            } else if band.state == .unauthorized {
                Button("Open Settings to allow Bluetooth") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        }
    }

    private var searchSection: some View {
        Section {
            if band.state == .scanning {
                HStack {
                    ProgressView().padding(.trailing, 6)
                    Text("Searching for heart-rate bands…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { band.stopScan() }
                }
            } else {
                Button { band.startScan() } label: {
                    Label("Search for bands", systemImage: "magnifyingglass")
                }
                .disabled(band.state == .bluetoothOff || band.state == .unauthorized)
            }
            ForEach(band.discovered) { device in
                Button {
                    band.pair(with: device.id)
                    appModel.sourcesChanged()
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(device.name).foregroundStyle(.primary)
                            Text("Signal \(device.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "cellularbars", variableValue: signal(device.rssi))
                        Text("Pair").foregroundStyle(.tint)
                    }
                }
            }
        } header: {
            Text("Pair a band")
        }
    }

    private var setupHelpSection: some View {
        Section("Band setup") {
            Label("Turn on heart-rate sharing (sometimes called broadcast mode) on your band, then tap Search for bands.", systemImage: "1.circle")
            Label("If your band has an option to stay visible, turn it on so OutPerform keeps recording in the background.", systemImage: "2.circle")
            Label("Keep your iPhone within Bluetooth range — data is only recorded while it's connected.", systemImage: "3.circle")
        }
        .font(.callout)
    }

    private var pairedSection: some View {
        Section("Device") {
            if let m = band.manufacturer { LabeledContent("Manufacturer", value: m) }
            if let m = band.model { LabeledContent("Model", value: m) }
            if let f = band.firmware { LabeledContent("Firmware", value: f) }
            NavigationLink {
                ZoneSettingsView()
            } label: {
                VStack(alignment: .leading) {
                    Text("Heart-rate zones & alerts")
                    Text("Set your zones and when your phone notifies you.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Forget band", role: .destructive) { confirmForget = true }
        }
    }

    private var recordingsSection: some View {
        Section("Recordings") {
            if let summary {
                LabeledContent("Days recorded", value: "\(summary.days)")
                LabeledContent("Storage", value: ByteCountFormatter.string(fromByteCount: Int64(summary.bytes), countStyle: .file))
                if let oldest = summary.oldest {
                    LabeledContent("Since", value: oldest.formatted(date: .abbreviated, time: .omitted))
                }
            }
            Button {
                Task {
                    rescoring = true
                    await appModel.refresh()
                    await loadSummary()
                    rescoring = false
                }
            } label: {
                HStack {
                    Label("Re-score from recordings", systemImage: "arrow.triangle.2.circlepath")
                    if rescoring { Spacer(); ProgressView() }
                }
            }
            .disabled(rescoring)
            Button("Delete recordings", role: .destructive) { confirmDelete = true }
        }
    }

    // MARK: Helpers

    private func loadSummary() async {
        summary = await StreamStore.shared.summary()
    }

    private var statusColor: Color {
        switch band.state {
        case .connected: return .green
        case .connecting, .reconnecting, .scanning: return .orange
        default: return .secondary
        }
    }

    private func batteryIcon(_ pct: Int) -> String {
        switch pct {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default:    return "battery.100percent"
        }
    }

    private func signal(_ rssi: Int) -> Double {
        Stats.clamp(Double(rssi + 100) / 50, 0, 1)
    }
}

/// Compact live-heart-rate strip for the Today screen.
struct LiveBandCard: View {
    @State private var band = BandManager.shared

    var body: some View {
        NavigationLink {
            BandView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: band.state == .connected ? "heart.fill" : "heart.slash")
                    .foregroundStyle(band.state == .connected ? .red : .secondary)
                    .symbolEffect(.pulse, isActive: band.liveBPM != nil)
                VStack(alignment: .leading, spacing: 2) {
                    Text(band.pairedName ?? "Bluetooth band").font(.subheadline.weight(.semibold))
                    Text(band.isPaired ? (band.isOffWrist ? "Off wrist" : band.state.label) : "Tap to pair")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let bpm = band.liveBPM {
                    Text("\(bpm)").font(.title2.bold().monospacedDigit())
                        .contentTransition(.numericText())
                    Text("bpm").font(.caption).foregroundStyle(.secondary)
                }
                if let battery = band.batteryLevel {
                    Text("\(battery)%").font(.caption).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}
