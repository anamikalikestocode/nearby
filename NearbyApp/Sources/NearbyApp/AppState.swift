import Foundation
import Combine

struct NearbyConfig: Codable {
    var imessageTo: String = ""
    var radiusMeters: Int = 800
    var cooldownHours: Int = 4
    var quietStart: Int = 23
    var quietEnd: Int = 8
    var myDeviceId: String = ""
}

struct NearbyState: Codable {
    var friends: [StoredFriend] = []
    var lastAlerted: [String: Date] = [:]  // findMyId -> last alert time
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

    private let configDir: URL
    private let configFile: URL
    private let stateFile: URL
    private let logFile: URL

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

    func appendLog(_ lines: [String]) {
        let text = lines.joined(separator: "\n") + "\n"
        if let data = text.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
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

    /// Run a proximity check. Safe to call from any thread —
    /// heavy work runs on the calling thread, @Published updates dispatch to main.
    func runCheck() {
        var stateCopy = state
        let logs = ProximityChecker.runCheck(config: config, state: &stateCopy)
        appendLog(logs)

        // All @Published mutations must happen on the main thread
        DispatchQueue.main.async {
            self.state = stateCopy
            self.lastCheckLog = logs
            self.save()
        }
    }

    func setup(imessageTo: String, radius: Int, friends: [FriendInfo], deviceId: String) {
        config.imessageTo = imessageTo
        config.radiusMeters = radius
        config.myDeviceId = deviceId
        state.friends = friends.map { StoredFriend(findMyId: $0.findMyId, name: $0.name, email: $0.email) }
        isSetUp = true
        save()
    }
}
