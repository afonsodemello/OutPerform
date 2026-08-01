//
//  WidgetBridge.swift
//  OutPerform
//
//  Publishes the latest scores to a shared App Group so the home/lock-screen
//  widgets (a separate process) can read them. Kept to plain values so no
//  SwiftData store sharing is required.
//

import Foundation
import WidgetKit

enum WidgetBridge {
    static let suiteName = "group.mamilles.OutPerform"

    enum Key {
        static let readiness = "w.readiness"
        static let recovery = "w.recovery"
        static let strain = "w.strain"
        static let sleep = "w.sleep"
        static let bedtime = "w.bedtime"        // epoch seconds
        static let updated = "w.updated"        // epoch seconds
        static let calibrating = "w.calibrating" // Int: nights done (<14) or -1 when ready
    }

    /// Sentinel for "no value yet".
    static let none = -1.0

    static func publish(readiness: Double?, recovery: Double?, strain: Double?,
                        sleepPerformance: Double?, bedtime: Date?, calibratingNights: Int?) {
        guard let d = UserDefaults(suiteName: suiteName) else { return }
        d.set(readiness ?? none, forKey: Key.readiness)
        d.set(recovery ?? none, forKey: Key.recovery)
        d.set(strain ?? none, forKey: Key.strain)
        d.set(sleepPerformance ?? none, forKey: Key.sleep)
        d.set(bedtime?.timeIntervalSince1970 ?? none, forKey: Key.bedtime)
        d.set(Date().timeIntervalSince1970, forKey: Key.updated)
        d.set(calibratingNights ?? -1, forKey: Key.calibrating)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
