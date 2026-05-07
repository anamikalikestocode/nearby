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

    /// Check if we can access the Find My data directory.
    static func canAccessFindMyData() -> Bool {
        return FileManager.default.isReadableFile(atPath: secureLocationCache.path)
    }

    /// Read and decrypt all friend locations from SecureLocationCache.
    static func decryptFriendLocations(key: Data) -> [String: (Double, Double)] {
        var locations: [String: (Double, Double)] = [:]
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
            locations[fmid] = (lat, lon)
        }
        return locations
    }

    /// Get your iPhone's GPS location from BeaconEstimatedLocation.
    static func getMyLocation(deviceId: String, key: Data) -> (Double, Double)? {
        let deviceDir = beaconEstimatedLocation.appendingPathComponent(deviceId)
        guard FileManager.default.isDirectory(deviceDir) else { return nil }
        guard let records = try? FileManager.default.contentsOfDirectory(
            at: deviceDir, includingPropertiesForKeys: nil
        ) else { return nil }

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
