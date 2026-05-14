import Foundation
import CryptoKit

/// Lightweight telemetry — fires and forgets to Supabase.
/// No PII collected. Device ID is a one-way hash.
struct Telemetry {
    // Supabase project (shared with The Drop)
    private static let supabaseURL = "https://tsixhtjsmwqadwgrawbs.supabase.co"
    private static let supabaseAnonKey = "sb_publishable_MXj7uW_tL2d80IkxJWx6kw_9r_3bxDO"

    static let appVersion = "1.2.0"

    // MARK: - Anonymous device ID

    /// One-way SHA256 hash of the hardware UUID. Can't be reversed to identify the user,
    /// but is stable across app restarts so we can count unique installs.
    static let anonymousId: String = {
        let raw = hardwareUUID() ?? UUID().uuidString
        let hash = SHA256.hash(data: Data(raw.utf8))
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }()

    private static func hardwareUUID() -> String? {
        let service = IOServiceMatching("IOPlatformExpertDevice")
        let platformExpert = IOServiceGetMatchingService(kIOMainPortDefault, service)
        defer { IOObjectRelease(platformExpert) }
        guard platformExpert != 0 else { return nil }
        let uuidRef = IORegistryEntryCreateCFProperty(platformExpert, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)
        return uuidRef?.takeRetainedValue() as? String
    }

    // MARK: - Event tracking

    static func trackSetup(friendCount: Int, radiusMeters: Int) {
        send(event: "setup_complete", extra: [
            "friend_count": friendCount,
            "radius_meters": radiusMeters
        ])
    }

    static func trackAppLaunch() {
        send(event: "app_launch", extra: [:])
    }

    static func trackCheck(friendCount: Int, friendsNearby: Int, alertsSent: Int, introsSent: Int) {
        send(event: "check", extra: [
            "friend_count": friendCount,
            "friends_nearby": friendsNearby,
            "alerts_sent": alertsSent,
            "intros_sent": introsSent
        ])

        // Also upsert the daily rollup
        upsertDaily(checks: 1, alerts: alertsSent, intros: introsSent)
    }

    /// Track onboarding funnel steps: moved_to_apps, fda_granted
    static func trackOnboarding(step: String) {
        send(event: "onboarding_step", extra: ["step": step])
    }

    static func trackAlert() {
        send(event: "alert_sent", extra: [:])
    }

    static func trackIntro() {
        send(event: "intro_sent", extra: [:])
    }

    // MARK: - Network

    private static func send(event: String, extra: [String: Any]) {
        var body: [String: Any] = [
            "device_id": anonymousId,
            "event": event,
            "app_version": appVersion
        ]
        for (k, v) in extra { body[k] = v }

        post(table: "nearby_events", body: body)
    }

    private static func upsertDaily(checks: Int, alerts: Int, intros: Int) {
        let today = ISO8601DateFormatter().string(from: Date()).prefix(10)  // "2026-05-08"
        let body: [String: Any] = [
            "device_id": anonymousId,
            "date": String(today),
            "checks": checks,
            "alerts": alerts,
            "intros": intros
        ]

        // Upsert: if row exists for this device+date, increment counters
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }
        guard let url = URL(string: "\(supabaseURL)/rest/v1/nearby_daily_active?on_conflict=device_id,date") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.httpBody = jsonData

        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    private static func post(table: String, body: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }
        guard let url = URL(string: "\(supabaseURL)/rest/v1/\(table)") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        // Fire and forget — telemetry should never block the app
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }
}
