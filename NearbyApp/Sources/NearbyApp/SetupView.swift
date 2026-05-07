import SwiftUI

struct SetupView: View {
    @ObservedObject var appState = AppStateManager.shared
    @State private var imessageAddress = ""
    @State private var radiusMeters: Double = 800
    @State private var status = ""
    @State private var friends: [FriendInfo] = []
    @State private var deviceId = ""
    @State private var deviceModel = ""
    @State private var isLoading = false
    @State private var discoveryDone = false
    @State private var discoveryFailed = false
    @State private var needsFDA = false
    @State private var fdaTimer: Timer?

    private let friendColors: [Color] = [
        .blue, .green, .orange, .purple, .pink, .cyan, .mint, .indigo, .teal, .yellow
    ]

    var body: some View {
        VStack(spacing: 0) {
            if needsFDA {
                fdaView
            } else if discoveryFailed {
                errorView
            } else if !discoveryDone {
                discoveryView
            } else if friends.isEmpty {
                noFriendsView
            } else {
                configView
            }
        }
        .frame(width: 400)
        .onAppear { checkAccess() }
        .onDisappear { fdaTimer?.invalidate() }
    }

    // MARK: - Full Disk Access

    var fdaView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            VStack(spacing: 8) {
                Text("One quick thing")
                    .font(.system(size: 20, weight: .semibold))
                Text("nearby reads Find My data on your Mac.\nFlip the toggle, then come back here.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                startFDAPolling()
            }) {
                Label("Open System Settings", systemImage: "gear")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .controlSize(.large)

            if fdaTimer != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for access...")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding(32)
    }

    // MARK: - Discovery (auto-runs)

    var discoveryView: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView()
                .controlSize(.large)

            VStack(spacing: 6) {
                Text("Finding your friends")
                    .font(.system(size: 18, weight: .semibold))
                Text(status)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(32)
    }

    // MARK: - Error state (key read failed, etc.)

    var errorView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            VStack(spacing: 8) {
                Text("Something went wrong")
                    .font(.system(size: 20, weight: .semibold))
                Text(status)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: {
                discoveryFailed = false
                discover()
            }) {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
        .padding(32)
    }

    // MARK: - No friends found

    var noFriendsView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.2.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("No friends found")
                    .font(.system(size: 20, weight: .semibold))
                Text("Make sure someone is sharing their\nlocation with you in Find My.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: {
                discoveryDone = false
                discover()
            }) {
                Label("Check Again", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
        .padding(32)
    }

    // MARK: - Config (the main screen)

    var configView: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 4) {
                Text("nearby")
                    .font(.system(size: 22, weight: .bold))
                Text("you'll get a text when they're close")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 24)
            .padding(.bottom, 20)

            // Friends list
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(friends.enumerated()), id: \.element.findMyId) { index, friend in
                        friendRow(friend: friend, color: friendColors[index % friendColors.count])
                    }
                }
                .padding(.horizontal, 20)
            }
            .frame(maxHeight: 240)

            if !deviceId.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "iphone")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("Using your \(cleanModelName(deviceModel)) for location")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 12)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                    Text("No iPhone found — nearby needs your iPhone's GPS to work")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                }
                .padding(.top, 12)
                .padding(.horizontal, 20)
            }

            Divider()
                .padding(.vertical, 16)
                .padding(.horizontal, 20)

            // iMessage field
            VStack(alignment: .leading, spacing: 6) {
                Text("Text me at")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                TextField("iMessage email or phone", text: $imessageAddress)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
            }
            .padding(.horizontal, 20)

            // Radius slider
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Alert when within")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(radiusLabel)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.blue)
                }
                Slider(value: $radiusMeters, in: 200...2000, step: 100)
                    .tint(.blue)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Spacer().frame(height: 20)

            // Start button
            Button(action: startNearby) {
                Text("Start nearby")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .controlSize(.large)
            .padding(.horizontal, 20)

            Text("Checks every ~10 min, even with the lid closed")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.6))
                .padding(.top, 8)
                .padding(.bottom, 20)
        }
    }

    // MARK: - Friend row (Find My style)

    func friendRow(friend: FriendInfo, color: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.gradient)
                    .frame(width: 34, height: 34)
                Text(initials(for: friend.name))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(friend.name)
                    .font(.system(size: 14, weight: .medium))
                Text(friend.email)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 16))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(10)
    }

    // MARK: - Helpers

    var radiusLabel: String {
        let m = Int(radiusMeters)
        let mins = max(1, m / 80)
        return "\(m)m (~\(mins) min walk)"
    }

    func initials(for name: String) -> String {
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))"
        }
        return String(name.prefix(2)).uppercased()
    }

    func cleanModelName(_ model: String) -> String {
        // "iPhone15,4" -> "iPhone"
        return model
            .components(separatedBy: ",").first?
            .replacingOccurrences(of: "[0-9]", with: "", options: .regularExpression) ?? model
    }

    func startNearby() {
        let r = Int(radiusMeters)
        appState.setup(
            imessageTo: imessageAddress,
            radius: r,
            friends: friends,
            deviceId: deviceId
        )
        Notifier.requestPermission()
        if !imessageAddress.isEmpty {
            Notifier.triggerMessagesPermission()
        }
        NSApplication.shared.keyWindow?.close()
    }

    // MARK: - Access & Discovery

    func checkAccess() {
        if LocationCache.canAccessFindMyData() {
            needsFDA = false
            fdaTimer?.invalidate()
            fdaTimer = nil
            discover()
        } else {
            needsFDA = true
        }
    }

    func startFDAPolling() {
        fdaTimer?.invalidate()
        fdaTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            if LocationCache.canAccessFindMyData() {
                DispatchQueue.main.async { checkAccess() }
            }
        }
    }

    func discover() {
        isLoading = true
        discoveryFailed = false
        status = "Reading encryption key..."
        DispatchQueue.global().async {
            guard let key = try? Crypto.readBeaconKey() else {
                DispatchQueue.main.async {
                    status = "Couldn't read the Find My encryption key.\nMake sure you're signed into iCloud."
                    discoveryFailed = true
                    isLoading = false
                }
                return
            }

            DispatchQueue.main.async { status = "Scanning Find My cache..." }
            let discoveredFriends = LocationCache.discoverFriends(key: key)

            DispatchQueue.main.async { status = "Looking for your iPhone..." }
            let phone = LocationCache.detectiPhone(key: key)

            DispatchQueue.main.async {
                friends = discoveredFriends
                deviceId = phone?.identifier ?? ""
                deviceModel = phone?.model ?? ""
                discoveryDone = true
                isLoading = false
            }
        }
    }
}
