import Foundation

struct ProximityChecker {
    // MARK: - Pairwise tuning constants

    /// Max GPS-age difference (minutes) between two friends for a valid comparison.
    /// If Friend A's data is 1 min old and Friend B's is 28 min old, skip — B could be miles away.
    static let maxTimestampDelta = 10

    /// Cooldown before re-alerting the same pair (seconds). 4 hours.
    static let pairCooldownSeconds: TimeInterval = 4 * 3600

    /// If a pair wasn't seen nearby for this long (seconds), treat next sighting as a new encounter.
    /// Resets the cooldown so "moved apart then came back" triggers a fresh alert.
    static let pairGapThreshold: TimeInterval = 30 * 60

    /// Max intro/group alerts per 10-min check cycle. Protects Blooio budget and user sanity.
    static let maxAlertsPerRun = 3

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
    /// Weekdays: 11pm–8am. Weekends: 2am–9am.
    static func isQuiet(start: Int, end: Int) -> Bool {
        let now = Date()
        let cal = Calendar.current
        let h = cal.component(.hour, from: now)
        let weekday = cal.component(.weekday, from: now)
        let isWeekend = weekday == 1 || weekday == 7  // Sun=1, Sat=7

        let s = isWeekend ? 2 : start
        let e = isWeekend ? 9 : end

        if s > e {
            return h >= s || h < e
        }
        return h >= s && h < e
    }

    /// Cooldown for a friend, adjusted by frequency.
    /// Regulars (4+ days/week): 24-hour cooldown (once per day max).
    /// Everyone else: normal cooldown from config.
    static func inCooldown(lastAlerted: Date?, cooldownHours: Int, isRegular: Bool) -> Bool {
        guard let last = lastAlerted else { return false }
        let effectiveCooldown = isRegular ? 24 * 3600.0 : Double(cooldownHours * 3600)
        return Date().timeIntervalSince(last) < effectiveCooldown
    }

    /// Run a full proximity check. Returns log messages.
    static func runCheck(config: NearbyConfig, state: inout NearbyState) -> [String] {
        var logs: [String] = []
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)

        guard let key = try? Crypto.readBeaconKey() else {
            logs.append("[\(ts)] Couldn't read encryption key from Keychain")
            return logs
        }

        // Get my location — returns nil if GPS data is extremely stale (>3 hours)
        guard !config.myDeviceId.isEmpty,
              let myLoc = LocationCache.getMyLocation(deviceId: config.myDeviceId, key: key) else {
            logs.append("[\(ts)] ⏸ Skipped — your iPhone GPS is unavailable or over 3 hours old")
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
            guard let loc = locations[friend.findMyId] else { continue }
            let dist = haversine(lat1: myLat, lon1: myLon, lat2: loc.lat, lon2: loc.lon)
            let dataAge = loc.age  // minutes since last GPS update

            guard dist < Double(config.radiusMeters) else { continue }

            // Record sighting for frequency dampening (even during quiet hours)
            state.friendFrequency[friend.findMyId, default: FriendFrequency()].recordSighting()
            let freq = state.friendFrequency[friend.findMyId]!
            let isRegular = freq.isRegular

            if quiet {
                logs.append("[\(ts)] 💤 \(friend.name) is \(Int(dist))m away but it's quiet hours")
                continue
            }

            if inCooldown(lastAlerted: state.lastAlerted[friend.findMyId], cooldownHours: config.cooldownHours, isRegular: isRegular) {
                let label = isRegular ? "regular, 24h cooldown" : "cooldown active"
                logs.append("[\(ts)] ⏳ \(friend.name) is \(Int(dist))m away (\(label))")
                continue
            }

            // Manhattan grid adds ~40% to straight-line distance, plus traffic lights.
            // 55 m/min effective speed is realistic for NYC walking.
            let mins = max(1, Int(dist * 1.4 / 55))
            let ageStr = dataAge < 5 ? "just now" : "\(dataAge) min ago"
            let safeName = Notifier.escapeForAppleScript(friend.name)
            let body = "\(safeName) is ~\(mins) min walk away (as of \(ageStr))"
            logs.append("[\(ts)] 🔔 \(body)")

            // Queue message for central sender (Anamika's Mac sends the iMessage)
            if !config.phoneNumber.isEmpty {
                MessageQueue.enqueue(to: config.phoneNumber, message: "Friend Nearby! \(body)")
                logs.append("[\(ts)] 📱 Queued for delivery")
            }
            // Also show a local macOS notification as backup
            Notifier.sendNotification(title: "nearby", body: body)

            state.lastAlerted[friend.findMyId] = Date()
            foundNearby = true
        }

        if !foundNearby {
            logs.append("[\(ts)] Checked \(locations.count) locations — no friends nearby")
        }

        // MARK: - Friend-pair intro check (clustered, rate-limited)
        //
        // Five protections vs. the naive O(n²) approach:
        //   1. Group Clustering  — 10 people at a wedding = 1 text, not 45
        //   2. Timestamp Delta   — skip pairs whose GPS ages differ by >10 min
        //   3. Cooldown Machine  — 4-hour cooldown, resets if they move apart ≥30 min
        //   4. Symmetry Guard    — j starts at i+1 (already correct, kept)
        //   5. Per-Run Rate Cap  — max 3 alerts per 10-min cycle

        if !quiet && !config.phoneNumber.isEmpty {
            let friendsWithLoc = state.friends.compactMap { friend -> (StoredFriend, Double, Double, Int)? in
                guard let loc = locations[friend.findMyId] else { return nil }
                return (friend, loc.lat, loc.lon, loc.age)
            }

            let now = Date()

            // ── Step 1: Build edges (valid nearby pairs) ──────────────────────
            struct Edge {
                let i: Int; let j: Int; let dist: Double; let pairKey: String
            }
            var edges: [Edge] = []

            for i in 0..<friendsWithLoc.count {
                for j in (i+1)..<friendsWithLoc.count {
                    let (friendA, latA, lonA, ageA) = friendsWithLoc[i]
                    let (friendB, latB, lonB, ageB) = friendsWithLoc[j]

                    // ── Protection #2: Timestamp Delta ────────────────────────
                    // If one friend's GPS is 1 min old and the other is 28 min old,
                    // comparing them is meaningless — the stale one could be miles away.
                    let delta = abs(ageA - ageB)
                    if delta > maxTimestampDelta {
                        logs.append("[\(ts)] ⏱ Skipped \(friendA.name)↔\(friendB.name): GPS age gap \(delta) min")
                        continue
                    }

                    let dist = haversine(lat1: latA, lon1: lonA, lat2: latB, lon2: lonB)
                    let walkMins = max(1, Int(dist * 1.4 / 55))
                    guard walkMins <= 5 else { continue }

                    // Stable alphabetical key — Protection #4 (symmetry)
                    let pairKey = [friendA.findMyId, friendB.findMyId].sorted().joined(separator: "|")

                    // ── Protection #3: Cooldown State Machine ─────────────────
                    if let ps = state.pairNotifications[pairKey] {
                        let sinceLast = now.timeIntervalSince(ps.lastNotified)
                        let sinceLastSeen = now.timeIntervalSince(ps.lastSeenNearby)

                        // Update "last seen nearby" so we can detect gaps later
                        state.pairNotifications[pairKey]?.lastSeenNearby = now

                        // Two ways to re-alert:
                        //   a) 4-hour cooldown expired
                        //   b) They moved apart (>30 min gap in sightings) then came back
                        let movedApart = sinceLastSeen > pairGapThreshold
                        if sinceLast < pairCooldownSeconds && !movedApart {
                            logs.append("[\(ts)] ⏳ \(friendA.name)↔\(friendB.name) in cooldown (\(Int(sinceLast/60)) min ago)")
                            continue
                        }
                    }

                    edges.append(Edge(i: i, j: j, dist: dist, pairKey: pairKey))
                }
            }

            guard !edges.isEmpty else { return logs }

            // ── Step 2: Union-Find clustering ─────────────────────────────────
            // Protection #1: 10 friends at a bar = 1 grouped text, not 45.
            var parent = Array(0..<friendsWithLoc.count)

            func find(_ x: Int) -> Int {
                var x = x
                while parent[x] != x {
                    parent[x] = parent[parent[x]]  // path compression
                    x = parent[x]
                }
                return x
            }

            for edge in edges {
                let rootA = find(edge.i), rootB = find(edge.j)
                if rootA != rootB { parent[rootA] = rootB }
            }

            // Group indices by cluster root
            var clusters: [Int: [Int]] = [:]
            for edge in edges {
                let root = find(edge.i)
                if clusters[root] == nil {
                    // Seed with all members reachable from this root
                    clusters[root] = []
                }
            }
            // Collect unique members per cluster
            var clusterMembers: [Int: Set<Int>] = [:]
            for edge in edges {
                let root = find(edge.i)
                clusterMembers[root, default: []].insert(edge.i)
                clusterMembers[root, default: []].insert(edge.j)
            }

            // ── Step 3: Build alert messages per cluster ──────────────────────
            struct PendingAlert {
                let pairKeys: [String]   // all pair keys in cluster (for cooldown bookkeeping)
                let message: String
                let minDist: Double      // closest pair distance (for ranking)
            }
            var pendingAlerts: [PendingAlert] = []

            for (_, memberSet) in clusterMembers {
                let members = Array(memberSet).sorted()
                let names = members.map { Notifier.escapeForAppleScript(friendsWithLoc[$0].0.name) }
                let pairKeys = edges.filter { memberSet.contains($0.i) && memberSet.contains($0.j) }
                                    .map { $0.pairKey }

                // Closest pair and worst freshness in this cluster
                let minDist = edges.filter { memberSet.contains($0.i) && memberSet.contains($0.j) }
                                   .map { $0.dist }.min() ?? 0
                let maxAge = members.map { friendsWithLoc[$0].3 }.max() ?? 0
                let walkMins = max(1, Int(minDist * 1.4 / 55))
                let ageStr = maxAge < 5 ? "just now" : "\(maxAge) min ago"

                let body: String
                if names.count == 2 {
                    body = "\(names[0]) and \(names[1]) are ~\(walkMins) min walk apart (as of \(ageStr)). Intro them?"
                } else {
                    // "Alice, Bob, and Carol are all within ~3 min walk of each other"
                    let allButLast = names.dropLast().joined(separator: ", ")
                    body = "\(allButLast), and \(names.last!) are all within ~\(walkMins) min walk (as of \(ageStr)). Group hangout?"
                }

                pendingAlerts.append(PendingAlert(pairKeys: pairKeys, message: body, minDist: minDist))
            }

            // ── Step 4: Rate-limit & send ─────────────────────────────────────
            // Protection #5: cap at 3 alerts per run, closest groups first.
            pendingAlerts.sort { $0.minDist < $1.minDist }
            let capped = pendingAlerts.prefix(maxAlertsPerRun)

            for alert in capped {
                logs.append("[\(ts)] 🤝 \(alert.message)")

                MessageQueue.enqueue(to: config.phoneNumber, message: "Intro opportunity! \(alert.message)")
                logs.append("[\(ts)] 📱 Intro queued for delivery")

                // Mark all pairs in this cluster as notified
                for key in alert.pairKeys {
                    state.pairNotifications[key] = PairState(lastNotified: now, lastSeenNearby: now)
                }
            }

            if pendingAlerts.count > maxAlertsPerRun {
                let skipped = pendingAlerts.count - maxAlertsPerRun
                logs.append("[\(ts)] 🔇 Rate-limited: \(skipped) more group(s) deferred to next cycle")
            }
        }

        return logs
    }
}
