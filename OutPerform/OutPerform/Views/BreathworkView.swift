//
//  BreathworkView.swift
//  OutPerform
//
//  Guided breathwork with an animated pacer
//

import SwiftUI

struct BreathPhase: Identifiable {
    let id = UUID()
    let label: String
    let seconds: Double
    let scale: CGFloat   // target circle scale during this phase
}

struct BreathProtocol: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
    let phases: [BreathPhase]

    static let physiologicalSigh = BreathProtocol(
        name: "Physiological sigh",
        detail: "Relaxation. Double nasal inhale, long oral exhale. Lowers HR within minutes (Huberman, Stanford 2023).",
        phases: [
            .init(label: "Inhale", seconds: 2, scale: 1.3),
            .init(label: "Inhale again", seconds: 1, scale: 1.5),
            .init(label: "Long exhale", seconds: 6, scale: 0.6)
        ])

    static let box = BreathProtocol(
        name: "Box breathing",
        detail: "Focus & calm. 4-4-4-4. Used by Navy SEALs to balance the nervous system.",
        phases: [
            .init(label: "Inhale", seconds: 4, scale: 1.5),
            .init(label: "Hold", seconds: 4, scale: 1.5),
            .init(label: "Exhale", seconds: 4, scale: 0.6),
            .init(label: "Hold", seconds: 4, scale: 0.6)
        ])

    static let cyclic = BreathProtocol(
        name: "Cyclic hyperventilation",
        detail: "Alertness. Faster paced breathing. Increases sympathetic activation — don't do while driving.",
        phases: [
            .init(label: "Inhale", seconds: 1.5, scale: 1.5),
            .init(label: "Exhale", seconds: 1.5, scale: 0.6)
        ])

    static let all = [physiologicalSigh, box, cyclic]
}

struct BreathworkView: View {
    @State private var selectedIndex = 0
    private var selected: BreathProtocol { BreathProtocol.all[selectedIndex] }
    @State private var running = false
    @State private var phaseIndex = 0
    @State private var circleScale: CGFloat = 0.8
    @State private var currentLabel = "Ready"
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 24) {
            Picker("Protocol", selection: $selectedIndex) {
                ForEach(BreathProtocol.all.indices, id: \.self) { i in
                    Text(BreathProtocol.all[i].name).tag(i)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedIndex) { _, _ in stop() }

            Text(selected.detail)
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal)

            Spacer()
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.opBlue, .opPurple], startPoint: .top, endPoint: .bottom))
                    .frame(width: 220, height: 220)
                    .scaleEffect(circleScale)
                    .animation(.easeInOut(duration: 0.5), value: circleScale)
                Text(currentLabel).font(.title2.bold()).foregroundStyle(.white)
            }
            Spacer()

            Button(running ? "Stop" : "Start") {
                running ? stop() : start()
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .tint(running ? .opRed : .accentColor)
        }
        .padding()
        .navigationTitle("Breathwork")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { stop() }
    }

    private func start() {
        running = true
        task = Task {
            while !Task.isCancelled {
                for phase in selected.phases {
                    if Task.isCancelled { break }
                    await MainActor.run {
                        currentLabel = phase.label
                        circleScale = phase.scale
                    }
                    try? await Task.sleep(for: .seconds(phase.seconds))
                }
            }
        }
    }

    private func stop() {
        task?.cancel(); task = nil
        running = false
        currentLabel = "Ready"
        circleScale = 0.8
    }
}
