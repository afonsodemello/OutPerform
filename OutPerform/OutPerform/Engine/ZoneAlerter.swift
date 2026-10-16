//
//  ZoneAlerter.swift
//  OutPerform
//
//  Phone notifications when your live heart rate moves into a new zone.
//
//  • Fed once per second with the band's smoothed heart rate.
//  • A zone change only counts after you've held it for 15 s, so a brief
//    spike or dip doesn't fire anything.
//  • Each zone notifies at most once every 90 s, and the alerts replace one
//    another in Notification Center instead of stacking up.
//  • Works with the app in the background: the band's Bluetooth updates keep
//    the app running, and the notification is local (nothing leaves the phone).
//

import Foundation
import UIKit
import UserNotifications

@MainActor
final class ZoneAlerter {
    static let shared = ZoneAlerter()

    static let holdSeconds: TimeInterval = 15
    static let cooldown: TimeInterval = 90

    private let zones = ZoneSettings.shared
    private var confirmedZone: Int?
    private var candidate: (zone: Int, since: Date)?
    private var lastAlert: [Int: Date] = [:]

    func observe(bpm: Int, at now: Date = Date()) {
        let zone = zones.zone(for: bpm)
        guard zone != confirmedZone else { candidate = nil; return }
        if candidate?.zone != zone { candidate = (zone, now); return }
        guard let c = candidate, now.timeIntervalSince(c.since) >= Self.holdSeconds else { return }

        let previous = confirmedZone
        confirmedZone = zone
        candidate = nil
        guard let previous, shouldAlert else { return }

        if zone > previous, zone >= 1, zones.notifyOnEnter[zone - 1] {
            alert(zone: zone, bpm: bpm, now: now,
                  title: "Zone \(zone) · \(ZoneSettings.name(zone))",
                  body: "\(bpm) bpm (\(zones.rangeText(zone))).",
                  haptic: zone >= 4 ? .warning : .success)
        } else if zone < previous, zone <= 1, previous >= 2, zones.notifyOnRecovery {
            alert(zone: 0, bpm: bpm, now: now,
                  title: "Recovered",
                  body: "Back down to \(bpm) bpm.",
                  haptic: .success)
        }
    }

    /// Forget the current zone (band disconnected, workout ended).
    func reset() {
        confirmedZone = nil
        candidate = nil
    }

    private var shouldAlert: Bool {
        switch zones.alertMode {
        case .off:            return false
        case .always:         return true
        case .duringWorkouts: return WorkoutRecorder.shared.isActive
        }
    }

    private func alert(zone: Int, bpm: Int, now: Date, title: String, body: String,
                       haptic: UINotificationFeedbackGenerator.FeedbackType) {
        if let last = lastAlert[zone], now.timeIntervalSince(last) < Self.cooldown { return }
        lastAlert[zone] = now

        if UIApplication.shared.applicationState == .active {
            UINotificationFeedbackGenerator().notificationOccurred(haptic)
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "hr-zones"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "hr-zone", content: content, trigger: nil))
    }

    /// Fire a sample alert from Settings.
    func sendTest() {
        let zone = 4
        let content = UNMutableNotificationContent()
        content.title = "Zone \(zone) · \(ZoneSettings.name(zone))"
        content.body = "This is how zone alerts look (\(zones.rangeText(zone)))."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "hr-zone", content: content, trigger: nil))
    }
}

/// Shows OutPerform's own notifications as banners even while the app is open
/// (iOS hides them by default when the app is in the foreground).
final class ForegroundNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ForegroundNotificationPresenter()

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
