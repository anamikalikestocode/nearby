import Foundation

/// Queues iMessage requests to Supabase for the central sender Mac to pick up and deliver.
/// User Macs INSERT into the queue (anon key). Anamika's Mac polls and sends via AppleScript.
struct MessageQueue {
    private static let supabaseURL = "https://tsixhtjsmwqadwgrawbs.supabase.co"
    private static let supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRzaXhodGpzbXdxYWR3Z3Jhd2JzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzIwODU1NjEsImV4cCI6MjA4NzY2MTU2MX0.nHylT0hHmOXQmi_T8KKE8sw7ecVYjhKrOGZzec3w6YA"

    /// Queue a message for delivery by the central sender.
    /// Fire-and-forget — failures are logged but don't block the app.
    static func enqueue(to phone: String, message: String) {
        let normalized = Notifier.normalizePhone(phone)
        let body: [String: Any] = [
            "recipient_phone": normalized,
            "message": message,
            "device_id": Telemetry.anonymousId,
            "status": "pending"
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }
        guard let url = URL(string: "\(supabaseURL)/rest/v1/message_queue") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                NSLog("MessageQueue enqueue failed: %@", error.localizedDescription)
            } else if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
                NSLog("MessageQueue enqueue HTTP %d", http.statusCode)
            }
        }.resume()
    }
}
