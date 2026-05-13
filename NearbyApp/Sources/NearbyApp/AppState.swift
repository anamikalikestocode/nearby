import Foundation
import Combine
import AppKit

struct NearbyConfig: Codable {
    var phoneNumber: String = ""
    var radiusMeters: Int = 800
    var cooldownHours: Int = 4
    var quietStart: Int = 23
    var quietEnd: Int = 8
    var myDeviceId: String = ""
}

/// Tracks the notification state for a friend pair.
struct PairState: Codable {
    var lastNotified: Date       // when we last sent an alert for this pair
    var lastSeenNearby: Date     // last time they were detected within radius
}

/// Tracks how often a friend is seen nearby (for frequency dampening).
struct FriendFrequency: Codable {
    var sightings: [Date] = []  // timestamps of nearby detections (rolling 7-day window)

    /// Number of distinct days this friend was seen nearby in the last 7 days.
    var daysSeenThisWeek: Int {
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .day, value: -7, to: Date())!
        let recentDays = Set(sightings.filter { $0 > cutoff }.map { cal.startOfDay(for: $0) })
        return recentDays.count
    }

    /// Is this a "regular" — someone you see 4+ days per week?
    var isRegular: Bool { daysSeenThisWeek >= 4 }

    /// Record a sighting and prune old entries.
    mutating func recordSighting() {
        let now = Date()
        sightings.append(now)
        // Keep only last 7 days
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: now)!
        sightings = sightings.filter { $0 > cutoff }
    }
}

struct NearbyState: Codable {
    var friends: [StoredFriend] = []
    var lastAlerted: [String: Date] = [:]       // findMyId -> last alert time
    var pairNotifications: [String: PairState] = [:]  // "idA|idB" -> pair state
    var friendFrequency: [String: FriendFrequency] = [:]  // findMyId -> frequency data
}

struct StoredFriend: Codable {
    let findMyId: String
    let name: String
    let email: String
}

class AppStateManager: ObservableObject {
    static let shared = AppStateManager()

    @Published var config = NearbyConfig()
    @Published var state = NearbyState()
    @Published var isSetUp = false
    @Published var lastCheckLog: [String] = []
    @Published var lastCheckTime: Date?

    private let configDir: URL
    private let configFile: URL
    private let stateFile: URL
    private let logFile: URL
    private let checkLock = NSLock()  // prevent concurrent runCheck() from clobbering state
    private var hasRefreshedOnce = false  // skip Find My refresh on first check (startup)

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        configDir = appSupport.appendingPathComponent("com.nearby")
        configFile = configDir.appendingPathComponent("config.json")
        stateFile = configDir.appendingPathComponent("state.json")
        logFile = configDir.appendingPathComponent("nearby.log")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        load()
    }

    func load() {
        if let data = try? Data(contentsOf: configFile),
           let config = try? JSONDecoder().decode(NearbyConfig.self, from: data) {
            self.config = config
            self.isSetUp = true
        }
        if let data = try? Data(contentsOf: stateFile),
           let state = try? JSONDecoder().decode(NearbyState.self, from: data) {
            self.state = state
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: configFile, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateFile, options: .atomic)
        }
    }

    private let maxLogSize = 500_000  // ~500KB, roughly a few thousand checks

    func appendLog(_ lines: [String]) {
        let text = lines.joined(separator: "\n") + "\n"
        if let data = text.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                // Rotate if too large — keep the last half
                if let attrs = try? FileManager.default.attributesOfItem(atPath: logFile.path),
                   let size = attrs[.size] as? Int, size > maxLogSize {
                    if let existing = try? String(contentsOf: logFile, encoding: .utf8) {
                        let half = existing.index(existing.startIndex, offsetBy: existing.count / 2)
                        // Find the next newline after the halfway point to avoid splitting a line
                        let cutPoint = existing[half...].firstIndex(of: "\n") ?? half
                        let trimmed = String(existing[cutPoint...])
                        try? trimmed.write(to: logFile, atomically: true, encoding: .utf8)
                    }
                }
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    /// Silently launch Find My to force a GPS refresh for the user's iPhone.
    /// searchpartyd only updates BeaconEstimatedLocation when Find My is active;
    /// without this, the user's own location goes stale within minutes.
    private func refreshFindMyData() {
        let findMyURL = URL(fileURLWithPath: "/System/Applications/FindMy.app")
        guard FileManager.default.fileExists(atPath: findMyURL.path) else {
            NSLog("nearby: Find My app not found at expected path")
            return
        }

        // Don't kill Find My if the user has it open
        let userHasItOpen = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.findmy" && !$0.isHidden
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = false           // don't bring Find My to front
        config.addsToRecentItems = false

        let sem = DispatchSemaphore(value: 0)
        var launchFailed = false
        NSWorkspace.shared.openApplication(at: findMyURL, configuration: config) { _, error in
            if error != nil { launchFailed = true }
            sem.signal()
        }
        // Timeout after 10 seconds — don't block forever if Find My can't launch
        let result = sem.wait(timeout: .now() + 10)
        if result == .timedOut || launchFailed {
            NSLog("nearby: Find My launch timed out or failed — skipping refresh")
            return
        }

        // Give searchpartyd time to fetch the updated location from iCloud
        Thread.sleep(forTimeInterval: 6)

        // Only quit Find My if we launched it (user didn't have it open)
        if !userHasItOpen {
            let quit = Process()
            quit.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            quit.arguments = ["-x", "FindMy"]
            try? quit.run()
            quit.waitUntilExit()
        }
    }

    func runCheck() {
        guard checkLock.try() else { return }  // skip if another check is already running
        defer { checkLock.unlock() }

        // Force Find My to refresh device locations before checking.
        // Skip on first launch to avoid interfering with the setup window.
        if hasRefreshedOnce {
            refreshFindMyData()
        }
        hasRefreshedOnce = true

        var stateCopy = state
        let logs = ProximityChecker.runCheck(config: config, state: &stateCopy)
        appendLog(logs)

        // Count alerts and intros from log lines for telemetry
        let alertCount = logs.filter { $0.contains("🔔") }.count
        let introCount = logs.filter { $0.contains("🤝") }.count
        let nearbyCount = logs.filter { $0.contains("🔔") || $0.contains("⏳") || $0.contains("💤") }.count
        Telemetry.trackCheck(
            friendCount: stateCopy.friends.count,
            friendsNearby: nearbyCount,
            alertsSent: alertCount,
            introsSent: introCount
        )

        // All @Published mutations must happen on the main thread
        DispatchQueue.main.async {
            self.state = stateCopy
            self.lastCheckLog = logs
            self.lastCheckTime = Date()
            self.save()
        }
    }

    func setup(phoneNumber: String, radius: Int, friends: [FriendInfo], deviceId: String) {
        config.phoneNumber = phoneNumber
        config.radiusMeters = radius
        config.myDeviceId = deviceId
        state.friends = friends.map { StoredFriend(findMyId: $0.findMyId, name: $0.name, email: $0.email) }
        isSetUp = true
        save()
    }
}
