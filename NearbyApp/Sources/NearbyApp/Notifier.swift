import Foundation
import UserNotifications

struct Notifier {
    // MARK: - iMessage via AppleScript

    /// Result of attempting to send a message.
    enum SendResult {
        case success
        case notAuthorized   // macOS Automation permission denied
        case trialExpired    // kept for API compat — unused with AppleScript
        case networkError
        case failed
    }

    // MARK: - AppleScript Escaping (Bulletproof)

    /// Escape a string for safe embedding inside AppleScript double-quoted strings.
    ///
    /// AppleScript uses backslash escapes inside `"..."`:
    ///   \"  →  literal double-quote
    ///   \\  →  literal backslash
    ///
    /// Single quotes, emojis, Unicode, curly quotes — all pass through unescaped
    /// because AppleScript treats them as normal characters inside `"..."`.
    ///
    /// We also strip control characters (tabs, newlines, etc.) to prevent
    /// script injection and ensure the one-liner stays on one line.
    static func escapeForAppleScript(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count + 8)
        for char in input {
            switch char {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n", "\r": result += " "     // flatten newlines to spaces
            case "\t": result += " "            // flatten tabs
            default:
                // Strip other ASCII control characters (0x00-0x1F, 0x7F)
                if let ascii = char.asciiValue, (ascii < 0x20 || ascii == 0x7F) {
                    continue
                }
                result.append(char)
            }
        }
        return result
    }

    // MARK: - Automation Permission Check

    /// Check if we have macOS Automation permission to control Messages.app.
    /// Runs a harmless AppleScript that touches Messages without sending anything.
    /// Returns .success if authorized, .notAuthorized if denied, .failed for other errors.
    static func checkAutomationPermission() -> SendResult {
        // "name" just returns the app name — doesn't send anything, doesn't activate the app
        let script = "tell application \"Messages\" to name"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let errPipe = Pipe()
        let outPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = outPipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                return .success
            }

            let errorData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errorStr = String(data: errorData, encoding: .utf8) ?? ""
            return classifyAppleScriptError(errorStr)
        } catch {
            return .failed
        }
    }

    /// Classify an AppleScript error string into a SendResult.
    /// Detects authorization denials vs. generic failures.
    private static func classifyAppleScriptError(_ error: String) -> SendResult {
        let lower = error.lowercased()
        // macOS returns these when Automation permission is denied or not yet granted
        if lower.contains("not authorized") ||
           lower.contains("not allowed") ||
           lower.contains("is not allowed assistive access") ||
           lower.contains("1743") ||         // errAEEventNotPermitted
           lower.contains("not permitted") ||
           lower.contains("application isn't running") {
            return .notAuthorized
        }
        return .failed
    }

    // MARK: - Send iMessage

    /// Send an iMessage via the macOS Messages app using AppleScript.
    /// Works with lid closed. Requires Messages to be signed in.
    static func sendIMessage(to: String, message: String, idempotencyKey: String? = nil) -> SendResult {
        let normalized = normalizePhone(to)
        let escapedMsg = escapeForAppleScript(message)
        let escapedTo = escapeForAppleScript(normalized)

        let script = """
        tell application "Messages"
            send "\(escapedMsg)" to buddy "\(escapedTo)" of (1st account whose service type = iMessage)
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let errPipe = Pipe()
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                return .success
            }

            let errorData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errorStr = String(data: errorData, encoding: .utf8) ?? ""
            NSLog("iMessage send failed: %@", errorStr)
            return classifyAppleScriptError(errorStr)
        } catch {
            NSLog("iMessage process error: %@", error.localizedDescription)
            return .networkError
        }
    }

    /// Send the setup confirmation text.
    static func sendWelcomeText(to: String) -> SendResult {
        return sendIMessage(
            to: to,
            message: "nearby is set up! You'll get texts here when friends are close."
        )
    }

    /// Test the notification connection.
    static func testConnection(to: String) -> SendResult {
        return sendIMessage(
            to: to,
            message: "nearby test — your notifications are working!"
        )
    }

    // MARK: - macOS Notifications (fallback)

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
