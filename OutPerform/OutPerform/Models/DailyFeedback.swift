//
//  DailyFeedback.swift
//  OutPerform
//
//  A timestamped "how I feel right now" log entry. Users can tap "Feeling focused"
//  or "Feeling energetic" at any point during the day; the engine accumulates these
//  over time to shift the predicted peak curves toward when the user actually peaks.
//

import Foundation
import SwiftData

@Model
final class DailyFeedback {
    var timestamp: Date
    var kind: DailyFeedback.Kind
    /// User self-rating 1–5 (1 = very low, 5 = peak).
    var intensity: Int = 3

    enum Kind: String, Codable, Identifiable {
        case focus
        case energy

        var id: String { rawValue }
        var label: String { self == .focus ? "Focus" : "Energy" }
        var icon: String  { self == .focus ? "brain.head.profile" : "bolt.fill" }
    }

    init(timestamp: Date = Date(), kind: Kind, intensity: Int = 3) {
        self.timestamp = timestamp
        self.kind = kind
        self.intensity = intensity
    }

    var hourOfDay: Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: timestamp)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
    }

    /// Emoji representation of intensity 1–5.
    var intensityLabel: String {
        switch intensity {
        case 1: return "Very low"
        case 2: return "Low"
        case 3: return "Moderate"
        case 4: return "High"
        default: return "Peak"
        }
    }

    var intensityDots: String { String(repeating: "●", count: intensity) + String(repeating: "○", count: 5 - intensity) }
}
