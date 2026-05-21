import SwiftUI

// MARK: - App Status

enum AppStatus: Equatable {
    case checking
    case needsMove
    case connectFindMy
    case noICloud          // searchpartyd dir doesn't exist — not signed into iCloud
    case fdaGrantedNoData  // FDA works but no friend data — Find My not set up
    case keychainPrompt    // about to ask for Keychain access — warn user first
    case discovering(String)
    case discoveryFailed(String)
    case noFriends
    case setup            // phone + friends, single screen
    case done

    static func == (lhs: AppStatus, rhs: AppStatus) -> Bool {
        switch (lhs, rhs) {
        case (.checking, .checking),
             (.needsMove, .needsMove),
             (.connectFindMy, .connectFindMy),
             (.noICloud, .noICloud),
             (.fdaGrantedNoData, .fdaGrantedNoData),
             (.keychainPrompt, .keychainPrompt),
             (.noFriends, .noFriends),
             (.setup, .setup),
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
    @State private var isRestarting = false
    @State private var isDiscovering = false  // guard against double discovery
    @State private var hasShownKeychainWarning = false
    @State private var fdaRetryCancel = false  // signal handleFDADone retry to stop
    @State private var fdaDoneAttempts = 0     // track how many times user clicked "done" without FDA
    @State private var dataTimer: Timer?       // polls for friend data after Find My opens
    @State private var dataPolling = false
    @State private var dataPollingStart: Date?  // when data polling began (for timeout message)

    var body: some View {
        VStack(spacing: 0) {
            switch status {
            case .checking:
                loadingView("getting things ready")
            case .needsMove:
                moveView
            case .connectFindMy:
                findMyView
            case .noICloud:
                noICloudView
            case .fdaGrantedNoData:
                noFindMyDataView
            case .keychainPrompt:
                keychainPromptView
            case .discovering(let msg):
                loadingView(msg)
            case .discoveryFailed(let reason):
                errorView(reason)
            case .noFriends:
                noFriendsView
            case .setup:
                setupView
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
            dataTimer?.invalidate()
            dataTimer = nil
            dataPolling = false
            fdaRetryCancel = true  // cancel any in-progress handleFDADone retry loop
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
                    // Show Keychain warning before first discovery attempt
                    // so the user isn't surprised by the system password prompt
                    if !hasShownKeychainWarning && !appState.isSetUp {
                        hasShownKeychainWarning = true
                        status = .keychainPrompt
                    } else {
                        discover()
                    }
                case .noFDA:
                    status = .connectFindMy
                case .noFindMyDir:
                    status = .noICloud
                case .noFriendData:
                    status = .fdaGrantedNoData
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
                friends = found
                selectedFriendIds = Set(found.map { $0.findMyId })
                deviceId = phone?.identifier ?? ""
                deviceModel = phone?.model ?? ""
                status = found.isEmpty ? .noFriends : .setup
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
                        if !hasShownKeychainWarning && !appState.isSetUp {
                            hasShownKeychainWarning = true
                            status = .keychainPrompt
                        } else {
                            discover()
                        }
                    } else if fdaStatus == .noFriendData || fdaStatus == .noFindMyDir {
                        // FDA was granted but there's a different problem
                        stopFDAPolling()
                        status = fdaStatus == .noFindMyDir ? .noICloud : .fdaGrantedNoData
                    }
                }
            }
        }
    }

    /// Handle "done — I turned it on" button.
    /// macOS TCC sometimes takes a few seconds to propagate FDA to the running process.
    /// We retry several times before falling back to a full relaunch.
    private func handleFDADone() {
        // Always stop polling timer when button is pressed — we take over from here
        stopFDAPolling()
        fdaRetryCancel = false

        let fdaStatus = LocationCache.checkFDAStatus()
        switch fdaStatus {
        case .granted:
            Telemetry.trackOnboarding(step: "fda_granted")
            if !hasShownKeychainWarning && !appState.isSetUp {
                hasShownKeychainWarning = true
                status = .keychainPrompt
            } else {
                discover()
            }
        case .noFindMyDir:
            status = .noICloud
        case .noFriendData:
            status = .fdaGrantedNoData
        case .noFDA:
            // TCC hasn't propagated yet — retry a few times before restarting
            isRestarting = true
            fdaDoneAttempts += 1
            let attemptNumber = fdaDoneAttempts
            DispatchQueue.global().async {
                for _ in 1...6 {
                    Thread.sleep(forTimeInterval: 1.0)
                    // Check if user closed the window or navigated away
                    if fdaRetryCancel { return }
                    let retryStatus = LocationCache.checkFDAStatus()
                    if retryStatus != .noFDA {
                        DispatchQueue.main.async {
                            isRestarting = false
                            preflight()
                        }
                        return
                    }
                }
                DispatchQueue.main.async {
                    isRestarting = false
                    // If user has tried multiple times without success, explain instead of restarting
                    if attemptNumber >= 2 {
                        status = .discoveryFailed("the permission change hasn't taken effect yet. try quitting Nearby (⌘Q), then reopen it from Applications")
                    } else {
                        // First failed attempt — relaunch automatically
                        relaunchApp()
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

    var findMyView: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 24) {
                ZStack {
                    Circle().fill(DS.blue.opacity(0.1)).frame(width: 72, height: 72)
                    Image(systemName: "lock.shield")
                        .font(.system(size: 30, weight: .medium)).foregroundStyle(DS.blue)
                }

                Text("turn on Nearby")
                    .font(.system(size: 22, weight: .bold)).foregroundColor(DS.textPrimary)
                Text("a Settings window just opened.\nfind **Nearby** in the list and flip its switch **on**.")
                    .font(.system(size: 14)).foregroundColor(DS.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)

                if showAddHint {
                    VStack(spacing: 4) {
                        Text("don't see Nearby in the list?")
                            .font(.system(size: 13, weight: .medium)).foregroundColor(DS.textSecondary)
                        Text("scroll to the bottom → click the **+** button →\nfind **Nearby** in your Applications folder → click Open")
                            .font(.system(size: 13)).foregroundColor(DS.textMuted)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                ActionButton(title: "open settings again", icon: "gear", color: DS.blue, style: .outline) {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    p.arguments = ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"]
                    try? p.run()
                }
                .padding(.horizontal, 24)

                ActionButton(title: isRestarting ? "applying..." : "done — I turned it on", icon: isRestarting ? nil : "checkmark", color: DS.green, isLoading: isRestarting) {
                    handleFDADone()
                }
                .padding(.horizontal, 24)
                .disabled(isRestarting)

                Text(isRestarting ? "checking permissions — one moment..." :
                     fdaDoneAttempts > 0 ? "make sure the toggle next to Nearby is on (blue)" :
                     "nearby will restart if needed to apply the change")
                    .font(.system(size: 12)).foregroundColor(fdaDoneAttempts > 0 ? DS.orange : DS.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .onAppear {
            // Reset state for fresh visit
            showAddHint = false
            isRestarting = false
            fdaRetryCancel = false

            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"]
            try? p.run()
            startFDAPolling()
            // Show the "don't see Nearby?" hint after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                // Only show if we're still on the FDA screen
                if case .connectFindMy = status {
                    withAnimation(.easeIn(duration: 0.3)) { showAddHint = true }
                }
            }
        }
    }

    // MARK: - Not signed into iCloud

    @State private var showDataPollingHint = false

    var noICloudView: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle().fill(DS.orange.opacity(0.1)).frame(width: 72, height: 72)
                Image(systemName: "location.slash")
                    .font(.system(size: 30, weight: .medium)).foregroundStyle(DS.orange)
            }
            VStack(spacing: 8) {
                Text("turn on Find My")
                    .font(.system(size: 22, weight: .bold)).foregroundColor(DS.textPrimary)
                Text("we opened Find My for you — make sure\nyou're signed in and **Share My Location**\nis turned on.\n\nnearby will continue automatically\nonce Find My syncs your friends.")
                    .font(.system(size: 14)).foregroundColor(DS.textSecondary)
                    .multilineTextAlignment(.center).lineSpacing(3)
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("waiting for Find My...")
                    .font(.system(size: 13, weight: .medium)).foregroundColor(DS.textMuted)
            }

            if showDataPollingHint {
                Text("taking a while? make sure Find My is open\nand at least one friend shares their location\nwith you. you can also try quitting Nearby\n(⌘Q) and reopening it.")
                    .font(.system(size: 12)).foregroundColor(DS.orange)
                    .multilineTextAlignment(.center).lineSpacing(2)
                    .transition(.opacity)
            }

            ActionButton(title: "open Find My", icon: "location", color: DS.orange, style: .outline) {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/FindMy.app"))
            }
            .padding(.horizontal, 40)
            ActionButton(title: "open iCloud settings", icon: "person.circle", color: DS.orange, style: .outline) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = ["x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane"]
                try? p.run()
            }
            .padding(.horizontal, 40)

            ActionButton(title: "try again", icon: "arrow.clockwise", color: DS.orange, style: .outline) {
                dataTimer?.invalidate()
                dataTimer = nil
                dataPolling = false
                preflight()
            }
            .padding(.horizontal, 40)

            Spacer()
        }
        .padding(32)
        .onAppear {
            showDataPollingHint = false
            // Auto-open Find My to help the user get set up
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/FindMy.app"))
            // Poll — once Find My syncs, the searchpartyd directory will appear
            startDataPolling()
            // Show hint after 60 seconds if still stuck
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                if case .noICloud = status {
                    withAnimation(.easeIn(duration: 0.3)) { showDataPollingHint = true }
                }
            }
        }
    }

    // MARK: - FDA granted but no Find My data

    /// Poll for friend data every 5 seconds — searchpartyd syncs after Find My opens.
    private func startDataPolling() {
        guard !dataPolling else { return }
        dataPolling = true
        dataPollingStart = Date()
        dataTimer?.invalidate()
        dataTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            DispatchQueue.global().async {
                let fdaStatus = LocationCache.checkFDAStatus()
                DispatchQueue.main.async {
                    guard dataPolling else { return }
                    if fdaStatus == .granted {
                        dataTimer?.invalidate()
                        dataTimer = nil
                        dataPolling = false
                        Telemetry.trackOnboarding(step: "fda_granted")
                        if !hasShownKeychainWarning && !appState.isSetUp {
                            hasShownKeychainWarning = true
                            status = .keychainPrompt
                        } else {
                            discover()
                        }
                    }
                    // If status changed to noFDA, need to show FDA screen
                    else if fdaStatus == .noFDA {
                        dataTimer?.invalidate()
                        dataTimer = nil
                        dataPolling = false
                        status = .connectFindMy
                    }
                    // .noFriendData or .noFindMyDir — keep polling,
                    // Find My may still be syncing / creating directories
                }
            }
        }
    }

    @State private var showSyncHint = false

    var noFindMyDataView: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle().fill(DS.green.opacity(0.1)).frame(width: 72, height: 72)
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 30, weight: .medium)).foregroundStyle(DS.green)
            }
            VStack(spacing: 8) {
                Text("waiting for Find My")
                    .font(.system(size: 22, weight: .bold)).foregroundColor(DS.textPrimary)
                Text("we opened Find My to sync your friends'\nlocations. this usually takes a few seconds.\n\nmake sure at least one friend is sharing\ntheir location with you.")
                    .font(.system(size: 14)).foregroundColor(DS.textSecondary)
                    .multilineTextAlignment(.center).lineSpacing(3)
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("syncing...")
                    .font(.system(size: 13, weight: .medium)).foregroundColor(DS.textMuted)
            }

            if showSyncHint {
                Text("still syncing? open Find My and check that\nyou see friends on the People tab.\nif not, ask a friend to share their location\nwith you first.")
                    .font(.system(size: 12)).foregroundColor(DS.orange)
                    .multilineTextAlignment(.center).lineSpacing(2)
                    .transition(.opacity)
            }

            ActionButton(title: "open Find My", icon: "location", color: DS.green, style: .outline) {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/FindMy.app"))
            }
            .padding(.horizontal, 40)

            ActionButton(title: "try again", icon: "arrow.clockwise", color: DS.green, style: .outline) {
                dataTimer?.invalidate()
                dataTimer = nil
                dataPolling = false
                preflight()
            }
            .padding(.horizontal, 40)

            Spacer()
        }
        .padding(32)
        .onAppear {
            showSyncHint = false
            // Auto-open Find My to trigger searchpartyd sync
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/FindMy.app"))
            startDataPolling()
            // Show hint after 45 seconds if still stuck
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
                if case .fdaGrantedNoData = status {
                    withAnimation(.easeIn(duration: 0.3)) { showSyncHint = true }
                }
            }
        }
    }

    // MARK: - Keychain prompt warning

    var keychainPromptView: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle().fill(DS.blue.opacity(0.1)).frame(width: 72, height: 72)
                Image(systemName: "key")
                    .font(.system(size: 30, weight: .medium)).foregroundStyle(DS.blue)
            }
            VStack(spacing: 8) {
                Text("one more thing")
                    .font(.system(size: 22, weight: .bold)).foregroundColor(DS.textPrimary)
                Text("your Mac is about to ask for your password.\nthis is normal — it's letting Nearby read\nyour Find My data.\n\ntap **Always Allow** so it won't ask again.")
                    .font(.system(size: 14)).foregroundColor(DS.textSecondary)
                    .multilineTextAlignment(.center).lineSpacing(3)
            }
            ProgressView().controlSize(.small)
            Spacer()
        }
        .padding(32)
        .onAppear {
            // Give the user 2 seconds to read the message, then auto-trigger
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if case .keychainPrompt = status {
                    discover()
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
            Spacer()
        }
        .padding(32)
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

    // MARK: - No Friends

    @State private var friendPollTimer: Timer?

    var noFriendsView: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle().fill(DS.purple.opacity(0.1)).frame(width: 72, height: 72)
                Image(systemName: "person.2.slash")
                    .font(.system(size: 28, weight: .medium)).foregroundStyle(DS.purple)
            }
            VStack(spacing: 8) {
                Text("no friends found yet")
                    .font(.system(size: 22, weight: .bold)).foregroundColor(DS.textPrimary)
                Text("open Find My and make sure at least one\nfriend is sharing their location with you.\n\nnearby will detect them automatically.")
                    .font(.system(size: 14)).foregroundColor(DS.textSecondary)
                    .multilineTextAlignment(.center).lineSpacing(3)
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("checking...")
                    .font(.system(size: 13, weight: .medium)).foregroundColor(DS.textMuted)
            }
            ActionButton(title: "open Find My", icon: "location", color: DS.purple, style: .outline) {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/FindMy.app"))
            }
            .padding(.horizontal, 40)
            Spacer()
        }
        .padding(32)
        .onAppear {
            // Auto-open Find My so user can set up location sharing
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/FindMy.app"))
            // Poll every 10 seconds — re-run discovery to check for new friends
            friendPollTimer?.invalidate()
            friendPollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
                DispatchQueue.global().async {
                    guard let key = try? Crypto.readBeaconKey() else { return }
                    let found = LocationCache.discoverFriends(key: key)
                    guard !found.isEmpty else { return }
                    let phone = LocationCache.detectiPhone(key: key)
                    DispatchQueue.main.async {
                        guard case .noFriends = status else { return }
                        friendPollTimer?.invalidate()
                        friendPollTimer = nil
                        friends = found
                        selectedFriendIds = Set(found.map { $0.findMyId })
                        deviceId = phone?.identifier ?? ""
                        deviceModel = phone?.model ?? ""
                        status = .setup
                    }
                }
            }
        }
        .onDisappear {
            friendPollTimer?.invalidate()
            friendPollTimer = nil
        }
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

            Text("you'll get iMessages when friends are close")
                .font(.system(size: 12)).foregroundColor(DS.textMuted)
                .padding(.top, 8).padding(.bottom, 18)
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

        // Queue a welcome text through Supabase (Anamika's Mac will send it)
        MessageQueue.enqueue(
            to: phoneNumber,
            message: "welcome to nearby! you'll get texts here when friends are close \u{1F44B}"
        )

        status = .done
        NSApplication.shared.keyWindow?.close()
    }
}
