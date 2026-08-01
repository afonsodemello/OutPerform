//
//  MoreView.swift
//  OutPerform
//
//  The "More" tab: less-frequent destinations (Body, Trends), Settings, and
//  links out to the website, privacy policy and support.
//

import SwiftUI

struct MoreView: View {
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { BodyView() } label: {
                        Label("Body", systemImage: "heart.text.square.fill")
                    }
                    NavigationLink { TrendsView() } label: {
                        Label("Trends", systemImage: "chart.xyaxis.line")
                    }
                }

                Section {
                    Button { showSettings = true } label: {
                        Label("Settings", systemImage: "gearshape.fill")
                            .foregroundStyle(.primary)
                    }
                }

                Section {
                    Link(destination: URL(string: "https://outperform.afonsodemello.com")!) {
                        Label("Website", systemImage: "safari")
                    }
                    Link(destination: URL(string: "https://outperform.afonsodemello.com/privacy.html")!) {
                        Label("Privacy policy", systemImage: "lock.shield")
                    }
                    Link(destination: URL(string: "https://outperform.afonsodemello.com")!) {
                        Label("Show me some love", systemImage: "heart.fill")
                    }
                } header: {
                    Text("OutPerform")
                } footer: {
                    Text("OutPerform is free, private and on-device. If it helps you, show me some love on my website. 💜")
                }
            }
            .navigationTitle("More")
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }
}
