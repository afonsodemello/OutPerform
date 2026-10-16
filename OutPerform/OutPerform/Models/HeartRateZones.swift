//
//  HeartRateZones.swift
//  OutPerform
//
//  Your five heart-rate training zones. Each zone starts at a bpm you can
//  set yourself; by default they sit at 50 / 60 / 70 / 80 / 90% of your max
//  heart rate (max HR = Tanaka 208 − 0.7 × age unless you enter your own).
//
//  Also holds the zone-alert preferences: when to notify, and which zones
//  notify on entry.
//

import Foundation
import Observation
import SwiftUI

@Observable
final class ZoneSettings {
    static let shared = ZoneSettings()

    enum AlertMode: String, Codable, CaseIterable {
        case off, duringWorkouts, always
        var displayName: String {
            switch self {
            case .off:            return "Off"
            case .duringWorkouts: return "During workouts"
            case .always:         return "Always"
            }
        }
    }

    static let zoneCount = 5
    static let defaultPercents: [Double] = [0.50, 0.60, 0.70, 0.80, 0.90]
    static let names = ["Recovery", "Endurance", "Tempo", "Threshold", "Max"]

    /// nil = estimate from age (Tanaka).
    var customMaxHR: Int? { didSet { save() } }
    /// Lower bound (bpm) of zones 1…5, ascending. nil = derive from % of max.
    var customLowerBounds: [Int]? { didSet { save() } }
    var alertMode: AlertMode = .duringWorkouts { didSet { save() } }
    /// Notify when entering each zone (index 0 = zone 1).
    var notifyOnEnter: [Bool] = [false, false, false, true, true] { didSet { save() } }
    /// Also notify when dropping back below zone 2 (recovered).
    var notifyOnRecovery = true { didSet { save() } }

    private let key = "zoneSettings.v1"
    private var loading = false

    private init() { load() }

    // MARK: Derived

    var estimatedMaxHR: Int { Int((208 - 0.7 * Double(AppSettings.shared.age)).rounded()) }
    var maxHR: Int { customMaxHR ?? estimatedMaxHR }

    /// Lower bpm bound of each zone, ascending.
    var lowerBounds: [Int] {
        if let b = customLowerBounds, b.count == Self.zoneCount { return b }
        return Self.defaultPercents.map { Int((Double(maxHR) * $0).rounded()) }
    }

    /// 1…5, or 0 below zone 1.
    func zone(for bpm: Int) -> Int {
        let b = lowerBounds
        return (0..<Self.zoneCount).last { bpm >= b[$0] }.map { $0 + 1 } ?? 0
    }

    /// "142–155 bpm" style range for a zone (1-based).
    func rangeText(_ zone: Int) -> String {
        let b = lowerBounds
        let lo = b[zone - 1]
        if zone == Self.zoneCount { return "\(lo)+ bpm" }
        return "\(lo)–\(b[zone] - 1) bpm"
    }

    static func name(_ zone: Int) -> String { zone >= 1 && zone <= zoneCount ? names[zone - 1] : "Rest" }

    static func color(_ zone: Int) -> Color {
        switch zone {
        case 1: return .gray
        case 2: return .blue
        case 3: return .green
        case 4: return .orange
        case 5: return .red
        default: return .secondary
        }
    }

    /// Set one zone's lower bound, keeping the zones ascending with ≥ 1 bpm each.
    func setLowerBound(zone: Int, bpm: Int) {
        var b = lowerBounds
        b[zone - 1] = bpm
        for i in zone..<Self.zoneCount where b[i] <= b[i - 1] { b[i] = b[i - 1] + 1 }
        for i in stride(from: zone - 2, through: 0, by: -1) where b[i] >= b[i + 1] { b[i] = b[i + 1] - 1 }
        customLowerBounds = b
    }

    func resetBoundsToPercentages() { customLowerBounds = nil }

    // MARK: Persistence

    private struct Snapshot: Codable {
        var customMaxHR: Int?
        var customLowerBounds: [Int]?
        var alertMode: AlertMode
        var notifyOnEnter: [Bool]
        var notifyOnRecovery: Bool
    }

    private func save() {
        guard !loading else { return }
        let s = Snapshot(customMaxHR: customMaxHR, customLowerBounds: customLowerBounds, alertMode: alertMode,
                         notifyOnEnter: notifyOnEnter, notifyOnRecovery: notifyOnRecovery)
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: key) }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        loading = true
        defer { loading = false }
        customMaxHR = s.customMaxHR
        customLowerBounds = s.customLowerBounds
        alertMode = s.alertMode
        notifyOnEnter = s.notifyOnEnter.count == Self.zoneCount ? s.notifyOnEnter : notifyOnEnter
        notifyOnRecovery = s.notifyOnRecovery
    }
}
