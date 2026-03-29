import Foundation
import UserNotifications

actor NotificationManager {
    static let shared = NotificationManager()
    private init() {}

    // Notification offsets: (seconds before pass, label, identifier suffix)
    private let offsets: [(TimeInterval, String, String)] = [
        (24 * 60 * 60, "24 hours",  "24h"),
        (     60 * 60, "1 hour",    "1h"),
        (        5 * 60, "5 minutes", "5m"),
    ]

    // MARK: - Permission

    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .authorized { return true }
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    var isAuthorized: Bool {
        get async {
            let s = await UNUserNotificationCenter.current().notificationSettings()
            return s.authorizationStatus == .authorized
        }
    }

    // MARK: - Schedule

    /// Cancels all previously scheduled ISS pass notifications then schedules
    /// T-24h, T-1h, and T-5min alerts for each upcoming pass.
    func scheduleNotifications(for passes: [ISSPass]) async {
        let center = UNUserNotificationCenter.current()
        // Remove all previously scheduled ISS alerts
        let pending = await center.pendingNotificationRequests()
        let issIDs  = pending.filter { $0.identifier.hasPrefix("iss-pass-") }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: issIDs)

        let now = Date()
        // iOS limits pending local notifications to 64; cap at the nearest ~20 passes
        let futurePasses = passes.filter { $0.start > now }.prefix(20)

        for pass in futurePasses {
            for (offset, label, suffix) in offsets {
                let fireDate = pass.start.addingTimeInterval(-offset)
                guard fireDate > now else { continue }

                let content = UNMutableNotificationContent()
                content.title = "ISS Pass in \(label)"
                content.body  = notificationBody(pass: pass, label: label)
                content.sound = .default

                let interval = fireDate.timeIntervalSinceNow
                let trigger  = UNTimeIntervalNotificationTrigger(
                    timeInterval: interval,
                    repeats: false
                )
                let id = "iss-pass-\(Int(pass.start.timeIntervalSince1970))-\(suffix)"
                let request = UNNotificationRequest(
                    identifier: id,
                    content:    content,
                    trigger:    trigger
                )
                try? await center.add(request)
            }
        }
    }

    // MARK: - Cancel

    func cancelAll() {
        let center = UNUserNotificationCenter.current()
        Task {
            let pending = await center.pendingNotificationRequests()
            let issIDs  = pending.filter { $0.identifier.hasPrefix("iss-pass-") }.map(\.identifier)
            center.removePendingNotificationRequests(withIdentifiers: issIDs)
        }
    }

    // MARK: - Helpers

    private func notificationBody(pass: ISSPass, label: String) -> String {
        let startTime = timeString(pass.start)
        let el        = String(format: "%.0f°", pass.maxElevation)
        let dir       = "\(pass.startCompass) → \(pass.endCompass)"
        let dur       = durationString(pass.duration)
        return "Visible at \(startTime) · Max \(el) · \(dir) · \(dur)"
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    private func durationString(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}
