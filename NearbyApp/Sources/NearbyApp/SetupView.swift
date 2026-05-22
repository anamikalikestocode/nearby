import SwiftUI

// MARK: - App Status

enum AppStatus: Equatable {
    case checking
    case needsMove
    case connectFindMy
    case syncing           // waiting for Find My data + friends — single unified waiting screen
    case discovering(String)
    case discoveryFailed(String)
    case setup            // phone + friends, single screen
    case complete         // "you're all set!" — shown briefly before closing
    case done

    static func == (lhs: AppStatus, rhs: AppStatus) -> Bool {
        switch (lhs, rhs) {
        case (.checking, .checking),
             (.needsMove, .needsMove),
             (.connectFindMy, .connectFindMy),
             (.syncing, .syncing),
             (.setup, .setup),
             (.complete, .complete),
             (.done, .done):
            return true
        case let (.discovering(a), .discovering(b)):
            return a == b
        case let (.discoveryFailed(a), .discoveryFailed(b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - Design System

private enum DS {
    static let bg = Color.white
    static let cardBg = Color(red: 0.97, green: 0.97, blue: 0.98)
    static let textPrimary = Color.black
    static let textSecondary = Color(red: 0.40, green: 0.40, blue: 0.43)
    static let textMuted = Color(red: 0.62, green: 0.62, blue: 0.65)
    static let blue = Color(red: 0.25, green: 0.48, blue: 1.0)
    static let green = Color(red: 0.18, green: 0.75, blue: 0.50)
    static let orange = Color(red: 1.0, green: 0.58, blue: 0.0)
    static let red = Color(red: 0.95, green: 0.28, blue: 0.28)
    static let purple = Color(red: 0.58, green: 0.35, blue: 0.98)
    static let border = Color(red: 0.92, green: 0.92, blue: 0.93)

    static let avatarColors: [Color] = [
        Color(red: 0.25, green: 0.48, blue: 1.0),
        Color(red: 0.58, green: 0.35, blue: 0.98),
        Color(red: 0.18, green: 0.75, blue: 0.50),
        Color(red: 1.0, green: 0.58, blue: 0.0),
        Color(red: 0.95, green: 0.35, blue: 0.50),
        Color(red: 0.0, green: 0.72, blue: 0.82),
        Color(red: 0.85, green: 0.45, blue: 0.95),
        Color(red: 0.40, green: 0.72, blue: 0.25),
    ]
}

// MARK: - Components

private struct AnimatedProgressBar: View {
    @State private var progress: CGFloat = 0
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(DS.border).frame(height: 6)
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [DS.blue, DS.purple], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * progress, height: 6)
            }
        }
        .frame(height: 6)
        .onAppear {
            withAnimation(.easeOut(duration: 2.0)) { progress = 0.7 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation(.easeOut(duration: 8.0)) { progress = 0.92 }
            }
        }
    }
}

private struct ActionButton: View {
    let title: String
    var icon: String? = nil
    var color: Color = DS.blue
    var style: ButtonVariant = .filled
    var isLoading: Bool = false
    let action: () -> Void
    enum ButtonVariant { case filled, outline }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().controlSize(.small).tint(style == .filled ? .white : color)
                } else if let icon = icon {
                    Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                }
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(style == .filled ? color : color.opacity(0.06))
            .foregroundColor(style == .filled ? .white : color)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(style == .outline ? color.opacity(0.3) : .clear, lineWidth: 1.5)
            )
            .shadow(color: style == .filled ? color.opacity(0.25) : .clear, radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }
}

private struct ModernTextField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(DS.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(DS.border, lineWidth: 1)
            )
    }
}

// MARK: - Main View

struct SetupView: View {
    @ObservedObject var appState = AppStateManager.shared

    @State private var status: AppStatus = .checking
    @State private var phoneNumber = ""
    @State private var radiusMinutes: Double = 10
    @State private var friends: [FriendInfo] = []
    @State private var selectedFriendIds: Set<String> = []
    @State private var deviceId = ""
    @State private var deviceModel = ""
    @State private var fdaTimer: Timer?
    @State private var fdaPolling = false
    @State private var isMoving = false
    @State private var showAddHint = false
    @State private var isDiscovering = false  // guard against double discovery
    @State private var syncTimer: Timer?       // unified poll for Find My data + friends
    @State private var syncPolling = false

    var body: some View {
        VStack(spacing: 0) {
            switch status {
            case .checking:
                loadingView("getting things ready")
            case .needsMove:
                moveView
            case .connectFindMy:
                findMyView
            case .syncing:
                syncingView
            case .discovering(let msg):
                loadingView(msg)
            case .discoveryFailed(let reason):
                errorView(reason)
            case .setup:
                setupView
            case .complete:
                completeView
            case .done:
                EmptyView()
            }
        }
        .frame(width: 420)
        .background(DS.bg)
        .onAppear {
            if phoneNumber.isEmpty, !appState.config.phoneNumber.isEmpty {
                phoneNumber = appState.config.phoneNumber
            }
            if appState.config.radiusMeters > 0 {
                radiusMinutes = Double(max(1, min(25, Int(Double(appState.config.radiusMeters) / 55.0 / 1.4) + 1)))
            }
            preflight()
        }
        .onDisappear {
            fdaTimer?.invalidate()
            fdaTimer = nil
            fdaPolling = false
            syncTimer?.invalidate()
            syncTimer = nil
            syncPolling = false
        }
    }

    // MARK: - Preflight

    static var isInBadLocation: Bool {
        let path = Bundle.main.bundlePath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return !path.hasPrefix("/Applications") && !path.hasPrefix("\(home)/Applications")
    }

    private func preflight() {
        if SetupView.isInBadLocation {
            // If a copy already exists in /Applications, just launch that one
            // instead of showing the "move" screen. This happens when the user
            // drags to Applications but then launches the DMG copy by mistake.
            let appsPath = "/Applications/Nearby.app"
            if FileManager.default.fileExists(atPath: appsPath) {
                let script = "sleep 1 && open \"\(appsPath)\""
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = ["-c", script]
                try? p.run()
                NSApp.terminate(nil)
                return
            }
            status = .needsMove
            return
        }

        // Retry FDA check a few times — macOS TCC can be slow to propagate
        // after a fresh relaunch, especially on first access
        DispatchQueue.global().async {
            var fdaStatus = LocationCache.checkFDAStatus()

            // If it looks like no FDA, retry twice with a short delay —
            // TCC daemon can lag behind on fresh launch
            if fdaStatus == .noFDA {
                for _ in 1...2 {
                    Thread.sleep(forTimeInterval: 0.5)
                    fdaStatus = LocationCache.checkFDAStatus()
                    if fdaStatus != .noFDA { break }
                }
            }

            DispatchQueue.main.async {
                switch fdaStatus {
                case .granted:
                    Telemetry.trackOnboarding(step: "fda_granted")
                    discover()
                case .noFDA:
                    status = .connectFindMy
                case .noFindMyDir, .noFriendData:
                    status = .syncing
                }
            }
        }
    }

    private func discover() {
        guard !isDiscovering else { return }  // prevent double discovery from timer + button race
        isDiscovering = true
        status = .discovering("finding your friends...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            // Only timeout if we're still in discovering state AND still flagged as discovering
            if case .discovering = status, isDiscovering {
                isDiscovering = false
                status = .discoveryFailed("taking too long — make sure you're signed into iCloud and try again")
            }
        }
        DispatchQueue.global().async {
            var key: Data?
            var lastError: Error?
            for _ in 1...3 {
                do {
                    key = try Crypto.readBeaconKey()
                    break
                } catch {
                    lastError = error
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
            guard let key = key else {
                DispatchQueue.main.async {
                    isDiscovering = false
                    if let cryptoErr = lastError as? CryptoError {
                        switch cryptoErr {
                        case .keyNotFound:
                            status = .discoveryFailed("Find My isn't set up on this Mac — open Find My, sign in with your Apple ID, and make sure \"Share My Location\" is turned on")
                        case .keychainFailed(let osStatus):
                            if osStatus == errSecUserCanceled || osStatus == errSecAuthFailed {
                                status = .discoveryFailed("nearby needs your password to read Find My data — click \"try again\" and tap \"Always Allow\" when your Mac asks for your password")
                            } else if osStatus == errSecInteractionNotAllowed {
                                status = .discoveryFailed("your Mac's keychain is locked — lock and unlock your Mac (or restart it), then try again")
                            } else {
                                status = .discoveryFailed("something went wrong reading your data (code \(osStatus)) — try restarting your Mac and reopening Nearby")
                            }
                        default:
                            status = .discoveryFailed("couldn't read your Find My data — try restarting your Mac and reopening Nearby")
                        }
                    } else {
                        status = .discoveryFailed("couldn't connect to Find My — make sure you're signed into iCloud and try again")
                    }
                }
                return
            }
            let found = LocationCache.discoverFriends(key: key)
            let phone = LocationCache.detectiPhone(key: key)
            DispatchQueue.main.async {
                isDiscovering = false
                deviceId = phone?.identifier ?? ""
                deviceModel = phone?.model ?? ""
                if found.isEmpty {
                    // No friends yet — go to syncing screen which will keep polling
                    status = .syncing
                } else {
                    friends = found
                    selectedFriendIds = Set(found.map { $0.findMyId })
                    status = .setup
                }
            }
        }
    }

    /// Stop FDA polling timer and reset state. Safe to call multiple times.
    private func stopFDAPolling() {
        fdaTimer?.invalidate()
        fdaTimer = nil
        fdaPolling = false
    }

    private func startFDAPolling() {
        guard !fdaPolling else { return }
        fdaPolling = true
        fdaTimer?.invalidate()
        fdaTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            // Do filesystem I/O off the main thread to avoid UI jank
            DispatchQueue.global().async {
                let fdaStatus = LocationCache.checkFDAStatus()
                DispatchQueue.main.async {
                    // Guard: if polling was stopped while we were checking, bail out
                    guard fdaPolling else { return }
                    if fdaStatus == .granted {
                        stopFDAPolling()
                        Telemetry.trackOnboarding(step: "fda_granted")
                        discover()
                    } else if fdaStatus == .noFriendData || fdaStatus == .noFindMyDir {
                        // FDA was granted but no friend data yet
                        stopFDAPolling()
                        status = .syncing
                    }
                }
            }
        }
    }

    private func relaunchApp() {
        let appPath = Bundle.main.bundlePath
        // Use a shell command to reopen the app after a short delay — this is reliable
        // unlike NSWorkspace.openApplication which silently fails on self-relaunch.
        // 2-second delay ensures the old process fully exits before reopening.
        let script = "sleep 2 && open \"\(appPath)\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script]
        try? p.run()
        // Quit immediately — the shell command reopens us in 2 seconds
        NSApp.terminate(nil)
    }

    // MARK: - 1. Move to Applications

    var moveView: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle().fill(DS.blue.opacity(0.1)).frame(width: 72, height: 72)
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 30, weight: .medium)).foregroundStyle(DS.blue)
            }
            VStack(spacing: 8) {
                Text("setting up...")
                    .font(.system(size: 22, weight: .bold)).foregroundColor(DS.textPrimary)
                Text("moving nearby to your Applications folder")
                    .font(.system(size: 14)).foregroundColor(DS.textSecondary)
                    .multilineTextAlignment(.center)
            }
            ProgressView().controlSize(.small)
            Spacer()
        }
        .padding(32)
        .onAppear {
            if !isMoving { moveToApplications() }
        }
    }

    private func moveToApplications() {
        isMoving = true
        let src = Bundle.main.bundleURL
        let dst = URL(fileURLWithPath: "/Applications/Nearby.app")
        DispatchQueue.global().async {
            do {
                if FileManager.default.fileExists(atPath: dst.path) {
                    try FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.copyItem(at: src, to: dst)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                p.arguments = ["-cr", dst.path]
                try p.run(); p.waitUntilExit()
                Telemetry.trackOnboarding(step: "moved_to_apps")
                DispatchQueue.main.async {
                    // Use shell command to reopen — NSWorkspace.openApplication silently fails on self-relaunch
                    let script = "sleep 1 && open \"\(dst.path)\""
                    let relaunch = Process()
                    relaunch.executableURL = URL(fileURLWithPath: "/bin/bash")
                    relaunch.arguments = ["-c", script]
                    try? relaunch.run()
                    NSApp.terminate(nil)
                }
            } catch {
                DispatchQueue.main.async {
                    isMoving = false
                    status = .discoveryFailed("couldn't move automatically — drag Nearby.app to your Applications folder, then reopen it")
                }
            }
        }
    }

    // MARK: - 2. Connect Find My (one screen, zero jargon)

    @State private var showFDARestartHint = false

    var findMyView: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 24) {
                ZStack {
                    Circle().fill(DS.blue.opacity(0.1)).frame(width: 72, height: 72)
                    Image(systemName: "lock.shield")
                        .font(.system(size: 30, weight: .medium)).foregroundStyle(DS.blue)
                }

                VStack(spacing: 6) {
                    Text("turn on Nearby")
                        .font(.system(size: 22, weight: .bold)).foregroundColor(DS.textPrimary)
                    Text("find **Nearby** in Settings → flip it **on**")
                        .font(.system(size: 14)).foregroundColor(DS.textSecondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("waiting...")
                        .font(.system(size: 13, weight: .medium)).foregroundColor(DS.textMuted)
                }

                if showAddHint {
                    Text("not there? click **+** → Applications → Nearby")
                        .font(.system(size: 12)).foregroundColor(DS.textMuted)
                        .multilineTextAlignment(.center)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if showFDARestartHint {
                    ActionButton(title: "restart nearby", icon: "arrow.clockwise", color: DS.orange, style: .outline) {
                        relaunchApp()
                    }
                    .padding(.horizontal, 40)
                    .transition(.opacity)
                } else {
                    ActionButton(title: "reopen settings", icon: "gear", color: DS.blue, style: .outline) {
                        let p = Process()
                        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                        p.arguments = ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"]
                        try? p.run()
                    }
                    .padding(.horizontal, 40)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .onAppear {
            showAddHint = false
            showFDARestartHint = false

            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"]
            try? p.run()
            startFDAPolling()
            // Show "don't see Nearby?" hint after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if case .connectFindMy = status {
                    withAnimation(.easeIn(duration: 0.3)) { showAddHint = true }
                }
            }
            // Show "already turned it on? restart" after 20 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                if case .connectFindMy = status {
                    withAnimation(.easeIn(duration: 0.3)) { showFDARestartHint = true }
                }
            }
        }
    }

    // MARK: - Syncing (unified waiting screen)

    /// Unified poll: checks FDA status, then tries full friend discovery.
    /// Replaces the old separate dataPolling + friendPollTimer.
    private func startSyncPolling() {
        guard !syncPolling else { return }
        syncPolling = true
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { _ in
            DispatchQueue.global().async {
                let fdaStatus = LocationCache.checkFDAStatus()

                // If FDA needed, switch to FDA screen
                if fdaStatus == .noFDA {
                    DispatchQueue.main.async {
                        guard syncPolling else { return }
                        syncTimer?.invalidate()
                        syncTimer = nil
                        syncPolling = false
                        status = .connectFindMy
                    }
                    return
                }

                // If data available, try full discovery
                if fdaStatus == .granted {
                    guard let key = try? Crypto.readBeaconKey() else { return }
                    let found = LocationCache.discoverFriends(key: key)
                    guard !found.isEmpty else { return }  // keep polling
                    let phone = LocationCache.detectiPhone(key: key)
                    DispatchQueue.main.async {
                        guard syncPolling, case .syncing = status else { return }
                        syncTimer?.invalidate()
                        syncTimer = nil
                        syncPolling = false
                        friends = found
                        selectedFriendIds = Set(found.map { $0.findMyId })
                        deviceId = phone?.identifier ?? ""
                        deviceModel = phone?.model ?? ""
                        status = .setup
                    }
                }
                // .noFriendData or .noFindMyDir — keep polling
            }
        }
    }

    @State private var showSyncHint = false

    var syncingView: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle().fill(DS.green.opacity(0.1)).frame(width: 72, height: 72)
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 30, weight: .medium)).foregroundStyle(DS.green)
            }
            VStack(spacing: 6) {
                Text("syncing your friends")
                    .font(.system(size: 22, weight: .bold)).foregroundColor(DS.textPrimary)
                Text("this usually takes a few seconds")
                    .font(.system(size: 14)).foregroundColor(DS.textSecondary)
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("syncing...")
                    .font(.system(size: 13, weight: .medium)).foregroundColor(DS.textMuted)
            }

            if showSyncHint {
                Text("no friends? open **Find My → People**\nand make sure someone shares with you.")
                    .font(.system(size: 12)).foregroundColor(DS.orange)
                    .multilineTextAlignment(.center).lineSpacing(2)
                    .transition(.opacity)
            }

            Spacer()
        }
        .padding(32)
        .onAppear {
            showSyncHint = false
            // Launch Find My hidden — just need it running to trigger searchpartyd sync
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-gjb", "com.apple.findmy"]
            try? p.run()
            startSyncPolling()
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
                if case .syncing = status {
                    withAnimation(.easeIn(duration: 0.3)) { showSyncHint = true }
                }
            }
        }
    }

    // MARK: - Loading

    func loadingView(_ text: String) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Text(text)
                .font(.system(size: 16, weight: .medium)).foregroundColor(DS.textPrimary)
            AnimatedProgressBar().padding(.horizontal, 60)
            if text.contains("friends") {
                Text("your Mac may ask for your password — tap **Always Allow**")
                    .font(.system(size: 12)).foregroundColor(DS.textMuted)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(32)
    }

    // MARK: - Complete

    var completeView: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("\u{1F389}").font(.system(size: 56))
            VStack(spacing: 8) {
                Text("you're all set!")
                    .font(.system(size: 22, weight: .bold)).foregroundColor(DS.textPrimary)
                Text("your iMessage bot is live")
                    .font(.system(size: 15, weight: .medium)).foregroundColor(DS.green)
            }
            HStack(spacing: 6) {
                Image(systemName: "menubar.rectangle")
                    .font(.system(size: 12))
                Text("nearby lives in your menu bar")
                    .font(.system(size: 13))
            }
            .foregroundColor(DS.textMuted)
            Spacer()
        }
        .padding(32)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                status = .done
                NSApplication.shared.keyWindow?.close()
            }
        }
    }

    // MARK: - Error

    func errorView(_ reason: String) -> some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle().fill(DS.orange.opacity(0.1)).frame(width: 72, height: 72)
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30, weight: .medium)).foregroundStyle(DS.orange)
            }
            VStack(spacing: 8) {
                Text("something went wrong")
                    .font(.system(size: 22, weight: .bold)).foregroundColor(DS.textPrimary)
                Text(reason)
                    .font(.system(size: 14)).foregroundColor(DS.textSecondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            ActionButton(title: "try again", icon: "arrow.clockwise", style: .outline) { preflight() }
                .padding(.horizontal, 40)
            Spacer()
        }
        .padding(32)
    }

    // MARK: - 3. Setup (phone + friends — one screen, one button)

    var setupView: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("nearby")
                    .font(.system(size: 28, weight: .bold)).foregroundColor(DS.textPrimary).tracking(-0.5)
                Text("you'll get a text when friends are close")
                    .font(.system(size: 14)).foregroundColor(DS.textSecondary)
            }
            .padding(.top, 20).padding(.bottom, 20)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(friends.enumerated()), id: \.element.findMyId) { i, friend in
                        friendRow(friend: friend, color: DS.avatarColors[i % DS.avatarColors.count])
                    }
                }
                .padding(.horizontal, 24)
            }
            .frame(maxHeight: 280)

            if !deviceId.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "iphone").font(.system(size: 11))
                    Text("using your \(cleanModelName(deviceModel))")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.green).padding(.top, 12)
            } else {
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
                        Text("no iPhone found").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(DS.orange)
                    Text("nearby uses your iPhone's GPS. make sure\nyour iPhone is in Find My → Devices.")
                        .font(.system(size: 11)).foregroundColor(DS.textMuted)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 12)
            }

            Rectangle().fill(DS.border).frame(height: 1)
                .padding(.vertical, 16).padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 8) {
                Text("your phone number")
                    .font(.system(size: 14, weight: .semibold)).foregroundColor(DS.textPrimary)
                ModernTextField(placeholder: "+1 (555) 123-4567", text: $phoneNumber)
            }
            .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("alert radius")
                        .font(.system(size: 14, weight: .semibold)).foregroundColor(DS.textPrimary)
                    Spacer()
                    Text("\(Int(radiusMinutes)) min walk")
                        .font(.system(size: 14, weight: .bold)).foregroundColor(DS.blue)
                }
                Slider(value: $radiusMinutes, in: 1...25, step: 1).tint(DS.blue)
            }
            .padding(.horizontal, 24).padding(.top, 14)

            Spacer().frame(height: 20)

            ActionButton(title: "start nearby", icon: "bolt.fill", color: DS.green) {
                finishSetup()
            }
            .padding(.horizontal, 24)
            .opacity(canFinishSetup ? 1 : 0.4)
            .disabled(!canFinishSetup)

            Spacer().frame(height: 18)
        }
    }

    // MARK: - Friend Row

    func friendRow(friend: FriendInfo, color: Color) -> some View {
        let on = selectedFriendIds.contains(friend.findMyId)
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                if on { selectedFriendIds.remove(friend.findMyId) }
                else { selectedFriendIds.insert(friend.findMyId) }
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(on ? color : color.opacity(0.2)).frame(width: 36, height: 36)
                    Text(initials(for: friend.name))
                        .font(.system(size: 13, weight: .bold)).foregroundColor(on ? .white : color)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.name)
                        .font(.system(size: 14, weight: .medium)).foregroundColor(on ? DS.textPrimary : DS.textMuted)
                    Text(friend.email)
                        .font(.system(size: 11)).foregroundColor(DS.textMuted)
                }
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(on ? color : .clear).frame(width: 22, height: 22)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(on ? color : DS.border, lineWidth: 2).frame(width: 22, height: 22)
                    if on {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                    }
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 14)
            .background(on ? color.opacity(0.04) : DS.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    func initials(for name: String) -> String {
        let parts = name.split(separator: " ")
        if parts.count >= 2 { return "\(parts[0].prefix(1))\(parts[1].prefix(1))" }
        return String(name.prefix(2)).uppercased()
    }

    func cleanModelName(_ model: String) -> String {
        model.components(separatedBy: ",").first?
            .replacingOccurrences(of: "[0-9]", with: "", options: .regularExpression) ?? model
    }

    /// Phone number has at least 10 digits (US) or starts with + and has 10+ digits
    private var isValidPhone: Bool {
        let digits = phoneNumber.filter { $0.isNumber }
        return digits.count >= 10
    }

    /// Can only finish setup with a valid phone and at least one friend selected
    private var canFinishSetup: Bool {
        isValidPhone && !selectedFriendIds.isEmpty
    }

    private var radiusMetersFromMinutes: Int {
        Int(radiusMinutes * 55.0 / 1.4)
    }

    private func finishSetup() {
        let r = radiusMetersFromMinutes
        let selected = friends.filter { selectedFriendIds.contains($0.findMyId) }
        appState.setup(phoneNumber: phoneNumber, radius: r, friends: selected, deviceId: deviceId)
        Notifier.requestPermission()
        Telemetry.trackSetup(friendCount: selected.count, radiusMeters: r)

        // Queue a welcome text — but only once per phone number
        let welcomeKey = "welcomed_\(Notifier.normalizePhone(phoneNumber))"
        if !UserDefaults.standard.bool(forKey: welcomeKey) {
            MessageQueue.enqueue(
                to: phoneNumber,
                message: "welcome to nearby! you'll get texts here when friends are close \u{1F44B}"
            )
            UserDefaults.standard.set(true, forKey: welcomeKey)
        }

        status = .complete
    }
}
