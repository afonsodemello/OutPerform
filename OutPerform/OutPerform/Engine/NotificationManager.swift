//
//  NotificationManager.swift
//  OutPerform
//
//  Bedtime reminders and health-monitor alerts.
//

import Foundation
import UserNotifications

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() async {
        let center = center
        _ = try? await PermissionGate.shared.run {
            try await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    /// Schedule a daily reminder 30 minutes before the recommended bedtime.
    func scheduleBedtimeReminder(at bedtime: Date) {
        center.removePendingNotificationRequests(withIdentifiers: ["bedtime"])
        let remindAt = bedtime.addingTimeInterval(-30 * 60)
        var comps = Calendar.current.dateComponents([.hour, .minute], from: remindAt)
        comps.second = 0

        let content = UNMutableNotificationContent()
        content.title = "Wind down soon"
        content.body = "Your optimal bedtime is in about 30 minutes. Aim to be in bed by \(Self.timeString(bedtime))."
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        center.add(UNNotificationRequest(identifier: "bedtime", content: content, trigger: trigger))
    }

    /// Schedule N daily "time to sync" reminders spread evenly from 8 AM to 8 PM.
    /// Calling this again replaces any previously scheduled reminders.
    func scheduleSyncReminders(count: Int) {
        let ids = (0..<10).map { "sync-reminder-\($0)" }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        guard count > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Time to sync OutPerform"
        content.body = "Open the app and tap Sync to keep your scores up to date."
        content.sound = .default

        // Spread evenly from 8:00 AM to 8:00 PM (12-hour window).
        for i in 0..<count {
            let fraction = count == 1 ? 0.5 : Double(i) / Double(count - 1)
            let totalMinutes = Int((8.0 + fraction * 12.0) * 60)
            var comps = DateComponents()
            comps.hour   = totalMinutes / 60
            comps.minute = totalMinutes % 60
            comps.second = 0
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
            center.add(UNNotificationRequest(identifier: "sync-reminder-\(i)",
                                              content: content, trigger: trigger))
        }
    }

    /// Fire a one-off health alert (illness pattern, low SpO2, etc.).
    func sendHealthAlert(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "health-\(UUID().uuidString)",
                                         content: content, trigger: nil))
    }

    private static func timeString(_ date: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short
        return f.string(from: date)
    }
}
