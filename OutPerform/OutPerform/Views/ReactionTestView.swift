//
//  ReactionTestView.swift
//  OutPerform
//
//  A short psychomotor-vigilance-style reaction test (the validated measure of
//  alertness). ~5 trials, ~1 minute. The result is stored and used to calibrate
//  the cognitive-readiness prediction to the individual.
//

import SwiftUI
import SwiftData

struct ReactionTestView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings

    /// The model's predicted readiness at the moment the test is started.
    var predictedNow: Double
    var onFinished: (() -> Void)?

    private enum Phase { case intro, waiting, go, tooSoon, finished }

    @State private var phase: Phase = .intro
    @State private var trial = 0
    @State private var stimulusAt: Date?
    @State private var reactions: [Double] = []     // ms
    @State private var falseStarts = 0
    @State private var lastRT: Double?
    @State private var delayTask: Task<Void, Never>?
    @State private var savedTest: FocusTest?

    private let totalTrials = 5

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            content.padding()
        }
        .contentShape(Rectangle())
        .onTapGesture { handleTap() }
        .overlay(alignment: .topTrailing) {
            Button { delayTask?.cancel(); dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2).foregroundStyle(.white.opacity(0.7))
            }.padding()
        }
        .onDisappear { delayTask?.cancel() }
    }

    private var background: Color {
        switch phase {
        case .go: return .opGreen
        case .tooSoon: return .opRed
        case .waiting: return .opBlue.opacity(0.85)
        default: return .black
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .intro:
            VStack(spacing: 18) {
                Image(systemName: "hand.tap.fill").font(.system(size: 60)).foregroundStyle(.white)
                Text("Reaction test").font(.title.bold()).foregroundStyle(.white)
                Text("When the screen turns **green**, tap as fast as you can. Wait for it — tapping early counts against you. \(totalTrials) quick rounds.")
                    .multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal)
                Button("Start") { startTrial() }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(.white)
                    .foregroundStyle(.black)
            }
        case .waiting:
            VStack(spacing: 12) {
                Text("Wait…").font(.largeTitle.bold()).foregroundStyle(.white)
                Text("Tap when it turns green").foregroundStyle(.white.opacity(0.8))
                trialCounter
            }
        case .go:
            VStack(spacing: 12) {
                Text("TAP!").font(.system(size: 64, weight: .heavy)).foregroundStyle(.white)
                trialCounter
            }
        case .tooSoon:
            VStack(spacing: 12) {
                Text("Too soon!").font(.largeTitle.bold()).foregroundStyle(.white)
                Text("Wait for green. Tap to continue.").foregroundStyle(.white.opacity(0.85))
            }
        case .finished:
            results
        }
    }

    private var trialCounter: some View {
        Text("Round \(min(trial + 1, totalTrials)) of \(totalTrials)")
            .font(.caption).foregroundStyle(.white.opacity(0.7))
    }

    private var results: some View {
        let mean = reactions.isEmpty ? 0 : Stats.mean(reactions)
        let best = reactions.min() ?? 0
        let lapses = reactions.filter { $0 > 500 }.count
        let measured = savedTest?.measuredAlertness ?? 0
        return VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 54)).foregroundStyle(.opGreen)
            Text("Measured alertness").font(.headline).foregroundStyle(.white)
            Text("\(Int(measured))").font(.system(size: 64, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            VStack(spacing: 6) {
                statRow("Average reaction", reactions.isEmpty ? "—" : "\(Int(mean)) ms")
                statRow("Fastest", best == 0 ? "—" : "\(Int(best)) ms")
                statRow("Lapses (>500 ms)", "\(lapses)")
                statRow("False starts", "\(falseStarts)")
                statRow("Predicted before test", "\(Int(predictedNow))")
            }
            .padding().background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            Text("This result fine-tunes your Focus prediction.")
                .font(.caption).foregroundStyle(.white.opacity(0.7))
            Button("Done") { onFinished?(); dismiss() }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(.white).foregroundStyle(.black)
        }.padding()
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.white.opacity(0.75))
            Spacer()
            Text(value).font(.body.weight(.semibold)).foregroundStyle(.white)
        }.font(.subheadline)
    }

    // MARK: Game logic

    private func handleTap() {
        switch phase {
        case .waiting:
            // Tapped before the stimulus.
            delayTask?.cancel()
            falseStarts += 1
            phase = .tooSoon
        case .go:
            if let s = stimulusAt {
                let rt = Date().timeIntervalSince(s) * 1000
                reactions.append(rt)
                lastRT = rt
            }
            advance()
        case .tooSoon:
            advance()
        default:
            break
        }
    }

    private func startTrial() {
        trial = 0; reactions = []; falseStarts = 0
        beginWaiting()
    }

    private func advance() {
        trial += 1
        if trial >= totalTrials {
            finish()
        } else {
            beginWaiting()
        }
    }

    private func beginWaiting() {
        phase = .waiting
        stimulusAt = nil
        let delay = Double.random(in: 1.5...4.0)
        delayTask?.cancel()
        delayTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run {
                if phase == .waiting {
                    stimulusAt = Date()
                    phase = .go
                }
            }
        }
    }

    private func finish() {
        let mean = reactions.isEmpty ? 0 : Stats.mean(reactions)
        let best = reactions.min() ?? 0
        let lapses = reactions.filter { $0 > 500 }.count
        let measured = CognitiveReadinessCalculator.measuredAlertness(meanReactionMs: mean, lapses: lapses)

        let test = FocusTest(date: Date(), meanReactionMs: mean, bestReactionMs: best,
                             lapses: lapses, falseStarts: falseStarts,
                             measuredAlertness: measured, predictedAtTest: predictedNow)
        context.insert(test)
        // Only calibrate from a clean run (no false starts and at least 3 taps).
        if falseStarts == 0, reactions.count >= 3 {
            settings.focusCalibrationOffset = CognitiveReadinessCalculator.updatedCalibrationOffset(
                previous: settings.focusCalibrationOffset,
                predictedAtTest: predictedNow, measured: measured)
        }
        try? context.save()
        savedTest = test
        phase = .finished
    }
}
