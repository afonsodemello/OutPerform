//
//  Components.swift
//  OutPerform
//
//  Reusable UI building blocks: score rings, metric tiles, section cards.
//

import SwiftUI

/// A circular progress ring with a centred value.
struct ScoreRing: View {
    var progress: Double          // 0...1
    var color: Color
    var lineWidth: CGFloat = 12
    var size: CGFloat = 160
    var title: String
    var value: String
    var caption: String?

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: progress)
            VStack(spacing: 2) {
                Text(value)
                    .font(.system(size: size * 0.28, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let caption {
                    Text(caption).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// Compact metric tile with name, value and optional trend/colour bar.
struct MetricTile: View {
    var name: String
    var value: String
    var systemImage: String
    var tint: Color = .opBlue
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(name, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Text(value)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Card wrapper with a title.
struct SectionCard<Content: View>: View {
    var title: String
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let systemImage { Image(systemName: systemImage).foregroundStyle(.secondary) }
                Text(title).font(.headline)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20))
    }
}

/// Horizontal bar showing a component contribution (0–100, 50 = baseline).
struct ContributionBar: View {
    var label: String
    var score: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(Fmt.score(score)).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 8)
                    Capsule()
                        .fill(barColor)
                        .frame(width: geo.size.width * CGFloat((score ?? 0) / 100), height: 8)
                }
            }
            .frame(height: 8)
        }
    }

    private var barColor: Color {
        guard let s = score else { return .gray }
        return s >= 67 ? .opGreen : (s >= 34 ? .opYellow : .opRed)
    }
}

/// A small pill label.
struct Pill: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Shown when there isn't enough data yet.
struct EmptyStateView: View {
    var title: String
    var message: String
    var systemImage: String = "chart.line.uptrend.xyaxis"
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
    }
}
