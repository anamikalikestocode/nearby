import Foundation

struct ProximityChecker {
    /// Haversine distance in meters between two GPS coordinates.
    static func haversine(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let R = 6371000.0
        let p1 = lat1 * .pi / 180
        let p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180
        let dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return R * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Check if current time is in quiet hours.
    static func isQuiet(start: Int, end: Int) -> Bool {
        let h = Calendar.current.component(.hour, from: Date())
        if start > end {
            return h >= start || h < end
        }
        return h >= start && h < end
    }

    /// Check if a friend is in cooldown (alerted recently).
    static func inCooldown(lastAlerted: Date?, cooldownHours: Int) -> Bool {
        guard let last = lastAlerted else { return false }
        return Date().timeIntervalSince(last) < Double(cooldownHours * 3600)
    }

    /// Run a full proximity check. Returns log messages.
    static func runCheck(config: NearbyConfig, state: inout NearbyState) -> [String] {
        var logs: [String] = []
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)

        guard let key = try? Crypto.readBeaconKey() else {
            logs.append("[\(ts)] Couldn't read encryption key from Keychain")
            return logs
        }

        // Get my location
        guard !config.myDeviceId.isEmpty,
              let myLoc = LocationCache.getMyLocation(deviceId: config.myDeviceId, key: key) else {
            logs.append("[\(ts)] Couldn't get your location")
            return logs
        }
        let (myLat, myLon) = myLoc
        logs.append("[\(ts)] 📍 iPhone GPS: \(String(format: "%.4f", myLat)), \(String(format: "%.4f", myLon))")

        // Get friend locations
        let locations = LocationCache.decryptFriendLocations(key: key)
        if locations.isEmpty {
            logs.append("[\(ts)] No locations found in cache")
            return logs
        }

        let quiet = isQuiet(start: config.quietStart, end: config.quietEnd)
        var foundNearby = false

        for friend in state.friends {
            guard let (lat, lon) = locations[friend.findMyId] else { continue }
            let dist = haversine(lat1: myLat, lon1: myLon, lat2: lat, lon2: lon)

            guard dist < Double(config.radiusMeters) else { continue }

            if quiet {
                logs.append("[\(ts)] 💤 \(friend.name) is \(Int(dist))m away but it's quiet hours")
                continue
            }

            if inCooldown(lastAlerted: state.lastAlerted[friend.findMyId], cooldownHours: config.cooldownHours) {
                logs.append("[\(ts)] ⏳ \(friend.name) is \(Int(dist))m away (cooldown active)")
                continue
            }

            let mins = max(1, Int(dist / 80))
            let body = "\(friend.name) is \(mins) min walk away (\(Int(dist))m)"
            logs.append("[\(ts)] 🔔 \(body)")

            // Send notifications
            if !config.imessageTo.isEmpty {
                if Notifier.sendIMessage(to: config.imessageTo, message: "Friend Nearby! 👋\n\(body)") {
                    logs.append("[\(ts)] 📱 iMessage sent to \(config.imessageTo)")
                } else {
                    logs.append("[\(ts)] iMessage failed — sending notification instead")
                }
            }
            Notifier.sendNotification(title: "nearby 👋", body: body)

            state.lastAlerted[friend.findMyId] = Date()
            foundNearby = true
        }

        if !foundNearby {
            logs.append("[\(ts)] Checked \(locations.count) locations — no friends nearby")
        }

        return logs
    }
}
