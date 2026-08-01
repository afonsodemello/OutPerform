//
//  MainTabView.swift
//  OutPerform
//

import SwiftUI
import Combine

struct MainTabView: View {
    @Environment(AppModel.self) private var appModel
    @State private var selection = 0
    @State private var tickNow = Date()

    var body: some View {
        TabView(selection: $selection) {
            Tab("Today", systemImage: "sun.max.fill", value: 0) { TodayView() }
            Tab("Perform", systemImage: "bolt.circle.fill", value: 1) { FocusView() }
            Tab("Sleep", systemImage: "bed.double.fill", value: 2) { SleepDetailView() }
            Tab("Strain", systemImage: "flame.fill", value: 3) { StrainDetailView() }
            Tab("More", systemImage: "ellipsis.circle.fill", value: 4) { MoreView() }
        }
        .safeAreaInset(edge: .top, spacing: 0) { syncBanner }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            tickNow = Date()
        }
    }

    @ViewBuilder
    private var syncBanner: some View {
        let engine = appModel.engine
        if engine.isRefreshing {
            // Applying phase — computation running, app may hitch.
            SyncBannerRow(
                icon: "gearshape.2.fill",
                color: .opBlue,
                label: "Computing your scores…",
                subtitle: "The app may briefly freeze — give it a moment.",
                actionLabel: nil,
                action: nil
            )
        } else if engine.isFetchingRaw {
            SyncBannerRow(
                icon: "arrow.triangle.2.circlepath",
                color: .opBlue,
                label: "Fetching new data…",
                subtitle: "The app may briefly freeze — give it a moment.",
                actionLabel: nil,
                action: nil
            )
        } else if engine.hasPendingData {
            SyncBannerRow(
                icon: "checkmark.circle.fill",
                color: .opGreen,
                label: "New data ready",
                subtitle: nil,
                actionLabel: "Apply",
                action: { Task { await appModel.applyPendingData() } }
            )
        } else if !engine.isRefreshing {
            let mins: Int? = engine.lastRefresh.map { Int(tickNow.timeIntervalSince($0) / 60) }
            if let m = mins, m >= 5 {
                SyncBannerRow(
                    icon: "clock.badge.exclamationmark",
                    color: .opYellow,
                    label: "Data not refreshed for \(m) min",
                    subtitle: nil,
                    actionLabel: "Sync",
                    action: { Task { await appModel.fetchNewData() } }
                )
            } else if engine.lastRefresh == nil {
                SyncBannerRow(
                    icon: "arrow.down.circle",
                    color: .opYellow,
                    label: "No data synced yet",
                    subtitle: nil,
                    actionLabel: "Sync",
                    action: { Task { await appModel.fetchNewData() } }
                )
            }
        }
    }
}

private struct SyncBannerRow: View {
    let icon: String
    let color: Color
    let label: String
    let subtitle: String?
    let actionLabel: String?
    let action: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let action, let actionLabel {
                Button(actionLabel, action: action)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(color.opacity(0.15), in: Capsule())
            } else if action == nil && actionLabel == nil {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.25), value: icon)
    }
}
