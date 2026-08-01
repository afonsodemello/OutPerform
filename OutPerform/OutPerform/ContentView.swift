//
//  ContentView.swift
//  OutPerform
//
//  Root: routes between onboarding and the main tab interface.
//

import SwiftUI

struct RootView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if settings.hasOnboarded {
            MainTabView()
        } else {
            OnboardingView()
        }
    }
}

#Preview {
    RootView()
        .environment(AppSettings.shared)
}
