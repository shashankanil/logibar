import Foundation
import UserNotifications

/// Posts a notification once when a device drops to 15% and re-arms after it charges past 25%.
enum BatteryAlerts {
    private static var warned = Set<String>()

    /// Notifications need an app bundle; skip them when running the bare binary (e.g. --dump).
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func check(_ device: LogiDevice) {
        guard available, UserDefaults.standard.object(forKey: "lowBatteryAlerts") as? Bool ?? true,
              let battery = device.state.battery, let percent = battery.percent else { return }
        if battery.charging || percent >= 25 {
            warned.remove(device.id)
            return
        }
        guard percent <= 15, warned.insert(device.id).inserted else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(device.state.name) battery low"
        content.body = "\(percent)% remaining."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "battery-\(device.id)", content: content, trigger: nil))
    }
}
