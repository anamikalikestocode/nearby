import SwiftUI

// MARK: - App Status

enum AppStatus: Equatable {
    case checking
    case needsMove
    case connectFindMy
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

    var body: some View {
        VStack(spacing: 0) {
            switch status {
            case .checking:
                loadingView("getting things ready")
            case .needsMove:
                moveView
            case .connectFindMy:
                findMyView
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
        }
    }

    // MARK: - Preflight

    static var isInBadLocation: Bool {
        !Bundle.main.bundlePath.hasPrefix("/Applications")
    }

    private func preflight() {
        if SetupView.isInBadLocation {
            status = .needsMove
        } else if LocationCache.canAccessFindMyData() {
            Telemetry.trackOnboarding(step: "fda_granted")
            discover()
        } else {
            status = .connectFindMy
        }
    }

    private func discover() {
        status = .discovering("finding your friends...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            if case .discovering = status {
                status = .discoveryFailed("taking too long — make sure you're signed into iCloud and try again")
            }
        }
        DispatchQueue.global().async {
            var key: Data?
            for _ in 1...3 {
                key = try? Crypto.readBeaconKey()
                if key != nil { break }
                Thread.sleep(forTimeInterval: 0.5)
            }
            guard let key = key else {
                DispatchQueue.main.async {
                    status = .discoveryFailed("couldn't read Find My data — make sure you're signed into iCloud")
                }
                return
            }
            let found = LocationCache.discoverFriends(key: key)
            let phone = LocationCache.detectiPhone(key: key)
            DispatchQueue.main.async {
                friends = found
                selectedFriendIds = Set(found.map { $0.findMyId })
                deviceId = phone?.identifier ?? ""
                deviceModel = phone?.model ?? ""
                status = found.isEmpty ? .noFriends : .setup
            }
        }
    }

    private func startFDAPolling() {
        guard !fdaPolling else { return }
        fdaPolling = true
        fdaTimer?.invalidate()
        fdaTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if LocationCache.canAccessFindMyData() {
                DispatchQueue.main.async {
                    fdaTimer?.invalidate()
                    fdaTimer = nil
                    fdaPolling = false
                    Telemetry.trackOnboarding(step: "fda_granted")
                    discover()
                }
            }
        }
    }

    private func relaunchApp() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        }
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
                Text("one sec")
                    .font(.system(size: 22, weight: .bold)).foregroundColor(DS.textPrimary)
                Text("nearby needs to move to your\nApplications folder first")
                    .font(.system(size: 14)).foregroundColor(DS.textSecondary)
                    .multilineTextAlignment(.center)
            }
            ActionButton(title: "move & continue", icon: "arrow.right", isLoading: isMoving) {
                moveToApplications()
            }
            .padding(.horizontal, 40)
            .disabled(isMoving)
            Spacer()
        }
        .padding(32)
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
                    NSWorkspace.shared.openApplication(at: dst, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
                    }
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
                Text("only one step")
                    .font(.system(size: 22, weight: .bold)).foregroundColor(DS.textPrimary)
                Text("we opened settings for you.\njust click on + and add nearby.\ntoggle on nearby.\nthat's it. promise.")
                    .font(.system(size: 14)).foregroundColor(DS.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)

                ActionButton(title: "done", icon: "checkmark", color: DS.blue) {
                    if LocationCache.canAccessFindMyData() {
                        Telemetry.trackOnboarding(step: "fda_granted")
                        discover()
                    } else {
                        // macOS often needs a relaunch for FDA to take effect
                        relaunchApp()
                    }
                }
                .padding(.horizontal, 24)
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .onAppear {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"]
            try? p.run()
            startFDAPolling()
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

    var noFriendsView: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle().fill(DS.purple.opacity(0.1)).frame(width: 72, height: 72)
                Image(systemName: "person.2.slash")
                    .font(.system(size: 28, weight: .medium)).foregroundStyle(DS.purple)
            }
            VStack(spacing: 8) {
                Text("no friends found")
                    .font(.system(size: 22, weight: .bold)).foregroundColor(DS.textPrimary)
                Text("make sure someone is sharing their\nlocation with you in Find My")
                    .font(.system(size: 14)).foregroundColor(DS.textSecondary)
                    .multilineTextAlignment(.center)
            }
            ActionButton(title: "check again", icon: "arrow.clockwise", color: DS.purple, style: .outline) { discover() }
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
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 11))
                    Text("no iPhone found").font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.orange).padding(.top, 12)
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
            .opacity(phoneNumber.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
            .disabled(phoneNumber.trimmingCharacters(in: .whitespaces).isEmpty)

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
