//
//  Theme.swift
//  OutPerform
//
//  Colours, gradients and value formatting shared across the UI.
//

import SwiftUI

// Defined on `ShapeStyle where Self == Color` so the leading-dot form works in
// both Color contexts (`Color.opGreen`) and ShapeStyle contexts
// (`.foregroundStyle(.opGreen)`).
extension ShapeStyle where Self == Color {
    static var opGreen: Color { Color(red: 0.30, green: 0.78, blue: 0.47) }
    static var opYellow: Color { Color(red: 0.98, green: 0.74, blue: 0.18) }
    static var opRed: Color { Color(red: 0.95, green: 0.35, blue: 0.35) }
    static var opBlue: Color { Color(red: 0.30, green: 0.62, blue: 0.95) }
    static var opPurple: Color { Color(red: 0.55, green: 0.45, blue: 0.95) }
}

extension RecoveryZone {
    var color: Color {
        switch self {
        case .green: return .opGreen
        case .yellow: return .opYellow
        case .red: return .opRed
        }
    }
}

extension StrainZone {
    var color: Color {
        switch self {
        case .light: return .opBlue
        case .moderate: return Color(red: 0.30, green: 0.72, blue: 0.85)
        case .high: return .opYellow
        case .allOut: return .opRed
        }
    }
}

extension ACWRZone {
    var color: Color {
        switch self {
        case .undertraining: return .opBlue
        case .sweetSpot: return .opGreen
        case .caution: return .opYellow
        case .highRisk: return .opRed
        }
    }
}

extension AlertLevel {
    var color: Color {
        switch self {
        case .normal: return .opGreen
        case .yellow: return .opYellow
        case .red: return .opRed
        }
    }
}

extension FocusZone {
    var color: Color {
        switch self {
        case .low: return .opRed
        case .moderate: return .opYellow
        case .high: return .opBlue
        case .peak: return .opPurple
        }
    }
}

func readinessColor(_ score: Double) -> Color {
    switch score {
    case ..<34: return .opRed
    case ..<67: return .opYellow
    default: return .opGreen
    }
}

// MARK: - Formatting

enum Fmt {
    static func minutes(_ min: Double?) -> String {
        guard let min, min > 0 else { return "—" }
        let h = Int(min) / 60, m = Int(min) % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    static func score(_ v: Double?) -> String {
        guard let v else { return "—" }
        return "\(Int(v.rounded()))"
    }

    static func pct(_ v: Double?) -> String {
        guard let v else { return "—" }
        return "\(Int(v.rounded()))%"
    }

    static func decimal(_ v: Double?, _ places: Int = 1) -> String {
        guard let v else { return "—" }
        return String(format: "%.\(places)f", v)
    }

    static func strain(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.1f", v)
    }

    static func time(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter(); f.timeStyle = .short
        return f.string(from: date)
    }
}
