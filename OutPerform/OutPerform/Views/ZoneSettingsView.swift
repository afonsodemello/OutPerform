//
//  ZoneSettingsView.swift
//  OutPerform
//
//  Set your five heart-rate zones and when the phone alerts you about them.
//

import SwiftUI

struct ZoneSettingsView: View {
    @State private var zones = ZoneSettings.shared
    @State private var customMax = false
    @State private var maxValue = 190

    var body: some View {
        @Bindable var zones = zones
        Form {
            Section {
                Toggle("Set my own max heart rate", isOn: $customMax)
                    .onChange(of: customMax) { _, on in zones.customMaxHR = on ? maxValue : nil }
                if customMax {
                    Stepper(value: $maxValue, in: 120...230) {
                        LabeledContent("Max heart rate", value: "\(maxValue) bpm")
                    }
                    .onChange(of: maxValue) { _, v in zones.customMaxHR = v }
                } else {
                    LabeledContent("Max heart rate", value: "\(zones.estimatedMaxHR) bpm")
                }
            } header: {
                Text("Max heart rate")
            } footer: {
                Text(customMax
                     ? "Use the highest heart rate you've seen in an all-out effort."
                     : "Estimated from your age (208 − 0.7 × age). Set your own if you know it from a test or race.")
            }

            Section {
                ForEach(1...ZoneSettings.zoneCount, id: \.self) { zone in
                    zoneRow(zone)
                }
                if zones.customLowerBounds != nil {
                    Button("Reset to 50/60/70/80/90% of max") { zones.resetBoundsToPercentages() }
                }
            } header: {
                Text("Zones")
            } footer: {
                Text("Each zone starts at the bpm shown. Zones stay in order; moving one nudges its neighbours.")
            }

            Section {
                Picker("Notify me", selection: $zones.alertMode) {
                    ForEach(ZoneSettings.AlertMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                if zones.alertMode != .off {
                    ForEach(1...ZoneSettings.zoneCount, id: \.self) { zone in
                        Toggle(isOn: Binding(
                            get: { zones.notifyOnEnter[zone - 1] },
                            set: { zones.notifyOnEnter[zone - 1] = $0 })) {
                            Label("Entering zone \(zone) · \(ZoneSettings.name(zone))", systemImage: "bell")
                        }
                        .tint(ZoneSettings.color(zone))
                    }
                    Toggle(isOn: $zones.notifyOnRecovery) {
                        Label("Back below zone 2 (recovered)", systemImage: "arrow.down.heart")
                    }
                    Button("Send a test alert") { ZoneAlerter.shared.sendTest() }
                }
            } header: {
                Text("Zone alerts")
            } footer: {
                Text("Alerts come from your band's live heart rate, also with the phone locked. A zone change counts after you've held it for 15 seconds, and each zone alerts at most once every 90 seconds.")
            }
        }
        .navigationTitle("Heart-rate zones")
        .onAppear {
            customMax = zones.customMaxHR != nil
            maxValue = zones.customMaxHR ?? zones.estimatedMaxHR
        }
    }

    private func zoneRow(_ zone: Int) -> some View {
        let lower = zones.lowerBounds[zone - 1]
        let pct = Int((Double(lower) / Double(zones.maxHR) * 100).rounded())
        return Stepper(value: Binding(
            get: { lower },
            set: { zones.setLowerBound(zone: zone, bpm: $0) }), in: 40...230) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3).fill(ZoneSettings.color(zone)).frame(width: 6, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Zone \(zone) · \(ZoneSettings.name(zone))").font(.subheadline.weight(.semibold))
                    Text("\(zones.rangeText(zone)) · \(pct)% of max").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
