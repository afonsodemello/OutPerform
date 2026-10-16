//
//  CombinedSourcesList.swift
//  OutPerform
//
//  The per-source rows shown in Settings when "All sources" is active:
//  an on/off switch for each, its live status, and how to connect it.
//

import SwiftUI

struct CombinedSourcesList: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppModel.self) private var appModel
    @Binding var showGoogleConnect: Bool
    private let board = SourceStatusBoard.shared
    @State private var appleNeedsAccess = false

    private func refreshAppleAccess() async {
        appleNeedsAccess = await HealthKitProvider().needsAuthorization()
    }

    var body: some View {
        ForEach(SourceKind.allCases, id: \.self) { kind in
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: binding(kind)) {
                    Label(kind.displayName, systemImage: kind.systemImage)
                }
                if settings.combinedSources.contains(kind) {
                    status(kind)
                    connectAction(kind)
                }
            }
        }
        Text("Apple Health and the band are read first. Google is only asked for what Apple Health is missing (e.g. HRV or skin temperature), so syncs stay fast. When sources overlap, OutPerform uses whichever has it first, then switches to the better one once it syncs. Heart rate and HRV: band → Apple Health → Google. Sleep: Apple Health → band → Google (one source per night, never mixed). Blood oxygen, skin temp and VO₂ max: Apple Health → Google.")
            .font(.caption2).foregroundStyle(.secondary)
            .task { await refreshAppleAccess() }
    }

    private func binding(_ kind: SourceKind) -> Binding<Bool> {
        Binding(
            get: { settings.combinedSources.contains(kind) },
            set: { on in
                if on { settings.combinedSources.insert(kind) } else { settings.combinedSources.remove(kind) }
                if kind == .band, on { Task { await BandManager.shared.startWhenReady() } }
                if kind == .appleHealth, on {
                    Task { try? await HealthKitProvider().requestAuthorization(); await refreshAppleAccess() }
                }
                appModel.sourcesChanged()
            })
    }

    @ViewBuilder private func status(_ kind: SourceKind) -> some View {
        let s = board.statuses[kind]
        Group {
            if let why = s?.notUsedReason {
                Label(why, systemImage: "minus.circle").foregroundStyle(.secondary)
            } else if let s, s.isFailing, let err = s.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if let ok = s?.lastSuccess {
                Label("Synced \(ok.formatted(.relative(presentation: .named)))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Waiting for first sync", systemImage: "clock").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    @ViewBuilder private func connectAction(_ kind: SourceKind) -> some View {
        switch kind {
        case .google:
            if !GoogleAuthManager.shared.isSignedIn {
                Button("Sign in with Google") { showGoogleConnect = true }.font(.caption)
            } else if settings.combinedSources.contains(.appleHealth) {
                Text("Only fetched for days and metrics Apple Health doesn't have.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        case .band:
            NavigationLink {
                BandView()
            } label: {
                Text(BandManager.shared.pairedName.map { "Band: \($0)" } ?? "Pair your band").font(.caption)
            }
        case .appleHealth:
            if appleNeedsAccess {
                Button("Allow Apple Health access") {
                    Task {
                        try? await HealthKitProvider().requestAuthorization()
                        await refreshAppleAccess()
                        appModel.sourcesChanged()
                        await appModel.refresh()
                    }
                }
                .font(.caption)
            }
        }
    }
}
