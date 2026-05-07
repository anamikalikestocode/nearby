import Foundation
import UserNotifications

struct Notifier {
    /// Send an iMessage via AppleScript.
    static func sendIMessage(to: String, message: String) -> Bool {
        let safeMsg = message.replacingOccurrences(of: "\"", with: "\\\"")
        let safeTo = to.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Messages"
            set targetService to 1st account whose service type = iMessage
            set targetBuddy to participant "\(safeTo)" of targetService
            send "\(safeMsg)" to targetBuddy
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else { return false }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        return error == nil
    }

    /// Show a macOS notification.
    static func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Request notification permission.
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Trigger Messages automation permission by accessing Messages.app.
    static func triggerMessagesPermission() {
        let script = NSAppleScript(source: "tell application \"Messages\" to name")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
    }
}
