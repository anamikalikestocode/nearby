import Foundation

struct FriendLocation {
    let findMyId: String
    let latitude: Double
    let longitude: Double
}

struct FriendInfo {
    let findMyId: String
    let name: String
    let email: String
}

struct LocationCache {
    private static let baseDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/com.apple.icloud.searchpartyd")

    static var secureLocationCache: URL { baseDir.appendingPathComponent("SecureLocationCache") }
    static var beaconEstimatedLocation: URL { baseDir.appendingPathComponent("BeaconEstimatedLocation") }
    static var ownedBeacons: URL { baseDir.appendingPathComponent("OwnedBeacons") }
    static var sharedKeys: URL { baseDir.appendingPathComponent("SecureLocationSharedKeys") }

    /// Check if we can actually read Find My data (not just the directory).
    /// Tests both directory listing and reading an actual .record file.
    static func canAccessFindMyData() -> Bool {
        guard FileManager.default.isReadableFile(atPath: secureLocationCache.path) else {
            return false
        }
        // Also verify we can list contents — catches partial FDA revocation
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: secureLocationCache, includingPropertiesForKeys: nil
        ) else {
            return false
        }
        // Try to read at least one .record file to confirm real access
        if let firstRecord = contents.first(where: { $0.pathExtension == "record" }) {
            return (try? Data(contentsOf: firstRecord)) != nil
        }
        // Directory exists and is listable but empty — still counts as access
        return true
    }

    /// Maximum age for friend locations — discard if older than this.
    /// Apple's searchpartyd updates friend locations every 5-15 min typically.
    static let maxFriendLocationAge: TimeInterval = 1800  // 30 min

    /// Maximum age for your own iPhone GPS.
    /// searchpartyd updates your own device GPS less frequently (sometimes 1-2 hours).
    /// 3 hours balances freshness vs. availability — stale enough to be wrong means
    /// we'd rather skip than send a bogus alert.
    static let maxOwnLocationAge: TimeInterval = 10800  // 3 hours

    /// Read and decrypt all friend locations from SecureLocationCache.
    /// When multiple records exist for the same friend, keeps the most recent.
    /// Discards locations older than `maxLocationAge`.
    static func decryptFriendLocations(key: Data) -> [String: (lat: Double, lon: Double, age: Int)] {
        var locations: [String: (lat: Double, lon: Double, age: Int)] = [:]
        var timestamps: [String: Double] = [:]  // track best timestamp per friend
        let now = Date().timeIntervalSince1970
        guard let records = try? FileManager.default.contentsOfDirectory(
            at: secureLocationCache, includingPropertiesForKeys: nil
        ) else { return locations }

        for record in records where record.pathExtension == "record" {
            guard let parsed = try? Crypto.decryptRecord(recordPath: record, key: key) else { continue }
            guard let secureLoc = parsed["secureLocation"] as? [String: Any],
                  let fmid = secureLoc["findMyId"] as? String,
                  let lat = secureLoc["latitude"] as? Double,
                  let lon = secureLoc["longitude"] as? Double,
                  lat != 0, lon != 0
            else { continue }

            // Extract timestamp — keep only the most recent location per friend
            var ts: Double = 0
            if let date = secureLoc["timestamp"] as? Date {
                ts = date.timeIntervalSince1970
            } else if let unix = secureLoc["timestamp"] as? Double {
                ts = unix
            } else if let str = secureLoc["timestamp"] as? String, let d = Double(str) {
                ts = d
            }

            // Skip stale friend data
            if ts > 0 && (now - ts) > maxFriendLocationAge {
                continue
            }

            let existing = timestamps[fmid] ?? 0
            if ts >= existing {
                let ageMinutes = ts > 0 ? Int((now - ts) / 60) : 0
                locations[fmid] = (lat: lat, lon: lon, age: ageMinutes)
                timestamps[fmid] = ts
            }
        }
        return locations
    }

    /// Get your iPhone's GPS location from BeaconEstimatedLocation.
    /// Returns nil if the most recent location is older than `maxLocationAge`.
    static func getMyLocation(deviceId: String, key: Data) -> (Double, Double)? {
        let deviceDir = beaconEstimatedLocation.appendingPathComponent(deviceId)
        guard FileManager.default.isDirectory(deviceDir) else { return nil }
        guard let records = try? FileManager.default.contentsOfDirectory(
            at: deviceDir, includingPropertiesForKeys: nil
        ) else { return nil }

        let now = Date().timeIntervalSince1970
        var bestTs: Double = 0
        var bestLat: Double?
        var bestLon: Double?

        for record in records where record.pathExtension == "record" {
            guard let parsed = try? Crypto.decryptRecord(recordPath: record, key: key) else { continue }
            let lat = parsed["latitude"] as? Double ?? 0
            let lon = parsed["longitude"] as? Double ?? 0
            guard lat != 0, lon != 0 else { continue }

            // Handle timestamp as Date, Double (unix), or String
            var ts: Double = 0
            if let date = parsed["timestamp"] as? Date {
                ts = date.timeIntervalSince1970
            } else if let unix = parsed["timestamp"] as? Double {
                ts = unix
            } else if let str = parsed["timestamp"] as? String, let d = Double(str) {
                ts = d
            }

            if ts > bestTs {
                bestTs = ts
                bestLat = lat
                bestLon = lon
            }
        }

        // Reject very stale GPS — searchpartyd updates own device infrequently
        if bestTs > 0 && (now - bestTs) > maxOwnLocationAge {
            return nil
        }

        if let lat = bestLat, let lon = bestLon {
            return (lat, lon)
        }
        return nil
    }

    /// Discover friends from SecureLocationSharedKeys.
    static func discoverFriends(key: Data) -> [FriendInfo] {
        var friends: [FriendInfo] = []
        var seenIds = Set<String>()
        guard let records = try? FileManager.default.contentsOfDirectory(
            at: sharedKeys, includingPropertiesForKeys: nil
        ) else { return friends }

        for record in records.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where record.pathExtension == "record" {
            guard let parsed = try? Crypto.decryptRecord(recordPath: record, key: key) else { continue }
            guard let fmid = parsed["findMyId"] as? String,
                  !seenIds.contains(fmid),
                  let ownerHandle = parsed["ownerHandle"] as? [String: Any],
                  let destination = ownerHandle["destination"] as? String
            else { continue }

            seenIds.insert(fmid)

            // Handle both email (mailto:) and phone (tel:) contacts
            let contact: String
            let name: String
            if destination.contains("mailto:") {
                let email = destination.components(separatedBy: "mailto:").last ?? ""
                guard !email.isEmpty else { continue }
                contact = email

                let local = email.components(separatedBy: "@").first ?? ""
                var parsed = local
                    .replacingOccurrences(of: ".", with: " ")
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "-", with: " ")
                // Remove trailing digits
                while let last = parsed.last, last.isNumber { parsed.removeLast() }
                parsed = parsed.trimmingCharacters(in: .whitespaces)
                name = parsed.isEmpty ? local : parsed.capitalized
            } else if destination.contains("tel:") {
                let phone = destination.components(separatedBy: "tel:").last ?? ""
                guard !phone.isEmpty else { continue }
                contact = phone
                name = phone  // No name derivable from phone number
            } else {
                continue
            }

            friends.append(FriendInfo(findMyId: fmid, name: name, email: contact))
        }
        return friends
    }

    /// Detect the user's iPhone from OwnedBeacons.
    static func detectiPhone(key: Data) -> (identifier: String, model: String)? {
        guard FileManager.default.isDirectory(ownedBeacons) else { return nil }
        guard let records = try? FileManager.default.contentsOfDirectory(
            at: ownedBeacons, includingPropertiesForKeys: nil
        ) else { return nil }

        var phones: [(pairingDate: String, identifier: String, model: String)] = []

        for record in records.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where record.pathExtension == "record" {
            guard let parsed = try? Crypto.decryptRecord(recordPath: record, key: key) else { continue }
            guard let model = parsed["model"] as? String,
                  let ident = parsed["identifier"] as? String,
                  model.contains("iPhone")
            else { continue }
            let hasLocation = FileManager.default.isDirectory(
                beaconEstimatedLocation.appendingPathComponent(ident)
            )
            guard hasLocation else { continue }
            let pairingDate = (parsed["pairingDate"] as? Date).map { "\($0)" } ?? ""
            phones.append((pairingDate, ident, model))
        }

        guard !phones.isEmpty else { return nil }
        phones.sort { $0.pairingDate > $1.pairingDate }
        return (phones[0].identifier, phones[0].model)
    }
}

extension FileManager {
    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
