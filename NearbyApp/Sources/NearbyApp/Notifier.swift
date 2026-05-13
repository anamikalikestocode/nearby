import Foundation
import UserNotifications

struct Notifier {
    // MARK: - String Escaping

    /// Escape a string for safe embedding in messages.
    /// Strips control characters and normalizes whitespace.
    static func escapeForAppleScript(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count + 8)
        for char in input {
            switch char {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n", "\r": result += " "
            case "\t": result += " "
            default:
                if let ascii = char.asciiValue, (ascii < 0x20 || ascii == 0x7F) {
                    continue
                }
                result.append(char)
            }
        }
        return result
    }

    // MARK: - macOS Notifications

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

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Helpers

    /// Normalize phone to E.164 format: +1XXXXXXXXXX
    static func normalizePhone(_ input: String) -> String {
        let digits = input.filter { $0.isNumber }
        if digits.count == 10 {
            return "+1\(digits)"
        } else if digits.count == 11 && digits.hasPrefix("1") {
            return "+\(digits)"
        }
        return input.hasPrefix("+") ? input : "+\(digits)"
    }
}
