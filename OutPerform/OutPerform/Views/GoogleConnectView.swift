//
//  GoogleConnectView.swift
//  OutPerform
//
//  Connect a Google account to sync via the Google Health API: paste the OAuth
//  client id (one-time), sign in (Google's consent screen approves the data
//  scopes), then pull data.
//

import SwiftUI
import UIKit

struct GoogleConnectView: View {
    /// Called after a successful sign-in + first sync.
    var onConnected: (() -> Void)?

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var clientID: String = GoogleHealthConfig.isConfigured ? GoogleHealthConfig.clientID : ""
    @State private var working = false
    @State private var status: String?
    @State private var error: String?
    @State private var signedIn = GoogleAuthManager.shared.isSignedIn
    @State private var diagnosing = false
    @State private var diagnosticsReport: String?

    private var clientLooksValid: Bool { clientID.contains("apps.googleusercontent.com") }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "g.circle.fill").font(.largeTitle).foregroundStyle(.opBlue)
                        VStack(alignment: .leading) {
                            Text("Google Health").font(.headline)
                            Text(signedIn ? "Connected" : "Not connected")
                                .font(.caption)
                                .foregroundStyle(signedIn ? .green : .secondary)
                        }
                    }
                }

                Section("OAuth client ID") {
                    TextField("…apps.googleusercontent.com", text: $clientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout.monospaced())
                    Text("One-time setup: in Google Cloud Console create a project, enable the Google Health API, and create an **iOS** OAuth client. Paste its client ID here.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            if working { ProgressView().padding(.trailing, 4) }
                            Image(systemName: "person.crop.circle.badge.checkmark")
                            Text(signedIn ? "Re-authorize Google" : "Sign in with Google")
                        }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || !clientLooksValid)

                    if signedIn {
                        Button {
                            Task { await runDiagnostics() }
                        } label: {
                            Label(diagnosing ? "Testing…" : "Test connection (diagnostics)",
                                  systemImage: "stethoscope")
                        }.disabled(diagnosing)

                        Button("Disconnect", role: .destructive) {
                            GoogleAuthManager.shared.signOut()
                            signedIn = false
                            status = "Disconnected."
                        }
                    }
                } footer: {
                    Text("You'll be taken to Google to approve access to your heart rate, HRV, sleep, blood oxygen, respiratory rate, temperature and activity data. Nothing leaves your device afterward.")
                }

                if let status { Section { Text(status).font(.caption).foregroundStyle(.secondary) } }
                if let error { Section { Text(error).font(.caption).foregroundStyle(.red) } }

                if let report = diagnosticsReport {
                    Section("Diagnostics") {
                        Button {
                            UIPasteboard.general.string = report
                            status = "Diagnostics copied — paste them to share."
                        } label: { Label("Copy diagnostics", systemImage: "doc.on.doc") }
                        ScrollView {
                            Text(report).font(.caption2.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(height: 260)
                    }
                }
            }
            .navigationTitle("Connect Google")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func runDiagnostics() async {
        diagnosing = true; diagnosticsReport = nil
        let cal = Calendar.current
        let to = Date()
        let from = cal.date(byAdding: .day, value: -7, to: to)!
        diagnosticsReport = await GoogleHealthProvider().diagnostics(from: from, to: to)
        diagnosing = false
    }

    private func signIn() async {
        working = true; error = nil; status = nil
        GoogleHealthConfig.setClientID(clientID)
        // Inside "All sources", signing in just adds Google to the mix.
        if appModel.settings.dataSource != .combined {
            appModel.switchSource(to: .googleHealth)
        }
        do {
            try await GoogleAuthManager.shared.signIn()   // presents Google consent
            signedIn = true
            // Don't make the user wait on the first sync here — enter the app and
            // let it load in the background (the Today tab shows progress).
            Task { await appModel.refresh() }
            onConnected?()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        working = false
    }
}
