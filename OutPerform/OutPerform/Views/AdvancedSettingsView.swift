//
//  AdvancedSettingsView.swift
//  OutPerform
//
//  Power-user controls to change the formulas: recovery & sleep weights, the
//  strain curve, the max-HR method. Edits are saved and the history is
//  recomputed on demand.
//

import SwiftUI

struct AdvancedSettingsView: View {
    @Environment(AlgorithmConfig.self) private var config
    @Environment(AppModel.self) private var appModel
    @State private var recomputing = false
    @State private var dirty = false

    var body: some View {
        @Bindable var config = config
        Form {
            Section {
                Text("Change how your scores are calculated. These are real knobs into the formulas — tap Apply to recompute your whole history with the new settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // MARK: Scoring model
            Section {
                Picker("Scoring model", selection: $config.scoringModel) {
                    ForEach(ScoringModel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }.onChange(of: config.scoringModel) { _,_ in dirty = true }
            } footer: {
                Text("Open-science: HRV-led Charge vs winsorised-EWMA baselines, Edwards %HRR TRIMP strain, Rest composite and 55% sleep-debt carry-over. The weights below apply to the classic model only.")
            }

            // MARK: Recovery weights
            Section("Recovery weights") {
                weightSlider("HRV", $config.wHRV)
                weightSlider("Resting HR", $config.wRHR)
                weightSlider("Respiratory rate", $config.wResp)
                weightSlider("Sleep performance", $config.wSleep)
                LabeledContent("Total (normalised)", value: String(format: "%.2f",
                    config.wHRV + config.wRHR + config.wResp + config.wSleep))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Skin-temperature penalty", isOn: $config.includeTempPenalty).onChange(of: config.includeTempPenalty) { _,_ in dirty = true }
                Toggle("Low blood-oxygen penalty", isOn: $config.includeSpo2Penalty).onChange(of: config.includeSpo2Penalty) { _,_ in dirty = true }
            }

            // MARK: Sleep weights
            Section("Sleep performance weights") {
                weightSlider("Efficiency", $config.spEfficiency)
                weightSlider("Restorative", $config.spRestorative)
                weightSlider("Need fulfilment", $config.spFulfillment)
                weightSlider("Consistency", $config.spConsistency)
            }

            // MARK: Strain
            Section("Strain") {
                Picker("Max-HR method", selection: $config.hrMaxMethod) {
                    ForEach(AlgorithmConfig.HRMaxMethod.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }.onChange(of: config.hrMaxMethod) { _,_ in dirty = true }
                paramSlider("Curve scale (TRIMP)", $config.strainScale, 50...400, step: 10)
                paramSlider("Curve coefficient", $config.strainCoefficient, 2...8, step: 0.1)
                Text("Higher scale → harder to accumulate strain. Higher coefficient → steeper curve.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            // MARK: Sleep need
            Section("Sleep need") {
                paramSlider("Default need (min)", $config.defaultSleepNeedMin, 360...600, step: 15)
                Text("Used before enough low-strain nights exist to learn your personal baseline.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Section {
                Button {
                    Task {
                        recomputing = true
                        config.save()
                        await appModel.refresh()
                        recomputing = false
                        dirty = false
                    }
                } label: {
                    HStack {
                        if recomputing { ProgressView().padding(.trailing, 4) }
                        Text(recomputing ? "Recomputing…" : "Apply & recompute")
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(recomputing)

                Button("Reset to defaults", role: .destructive) {
                    config.resetToDefaults()
                    dirty = true
                }
            } footer: {
                if dirty { Text("You have unsaved changes — tap Apply to recompute.") }
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func weightSlider(_ label: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(label); Spacer(); Text(String(format: "%.2f", value.wrappedValue)).foregroundStyle(.secondary) }
            Slider(value: value, in: 0...1, step: 0.05).onChange(of: value.wrappedValue) { _,_ in dirty = true }
        }
    }

    private func paramSlider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(label); Spacer(); Text(String(format: "%.0f", value.wrappedValue)).foregroundStyle(.secondary) }
            Slider(value: value, in: range, step: step).onChange(of: value.wrappedValue) { _,_ in dirty = true }
        }
    }
}
