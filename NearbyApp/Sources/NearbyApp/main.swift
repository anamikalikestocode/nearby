import AppKit
import SwiftUI
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    var setupWindow: NSWindow?
    var scheduler: NSBackgroundActivityScheduler?
    var backupTimer: Timer?          // backup timer in case NSBackgroundActivityScheduler is deferred
    var consecutiveFailures = 0      // track check failures for menu bar indicator

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarIcon()
        buildMenu()

        Telemetry.trackAppLaunch()

        if AppStateManager.shared.isSetUp {
            enableLoginItem()
            startScheduler()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                AppStateManager.shared.runCheck()
                DispatchQueue.main.async { self.buildMenu() }
            }
        } else {
            // Only show setup window for new users who haven't completed onboarding
            showSetup()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSetup()
        return false
    }

    // MARK: - Menu Bar

    func updateMenuBarIcon() {
        guard let button = statusItem.button else { return }

        if !AppStateManager.shared.isSetUp {
            button.title = " Finish Setup"
            if let img = NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: "Setup needed") {
                img.size = NSSize(width: 14, height: 14)
                img.isTemplate = true
                button.image = img
                button.imagePosition = .imageLeading
            }
        } else {
            button.title = ""
            if let img = NSImage(systemSymbolName: "location.fill", accessibilityDescription: "nearby") {
                img.size = NSSize(width: 14, height: 14)
                img.isTemplate = true
                button.image = img
                button.imagePosition = .imageOnly
            }
        }
    }

    func buildMenu() {
        let menu = NSMenu()

        if AppStateManager.shared.isSetUp {
            let friends = AppStateManager.shared.state.friends
            let count = friends.count
            let statusTitle = "\(count) friend\(count == 1 ? "" : "s") tracked"
            let item = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)

            if let lastLog = AppStateManager.shared.lastCheckLog.last {
                let cleaned = cleanLogForMenu(lastLog)
                let logItem = NSMenuItem(title: cleaned, action: nil, keyEquivalent: "")
                logItem.isEnabled = false
                menu.addItem(logItem)
            }

            if let lastCheck = AppStateManager.shared.lastCheckTime {
                let ago = Int(Date().timeIntervalSince(lastCheck) / 60)
                if ago > 30 {
                    let staleItem = NSMenuItem(title: "⚠️ Last check \(ago)m ago — is your Mac awake?", action: nil, keyEquivalent: "")
                    staleItem.isEnabled = false
                    menu.addItem(staleItem)
                }
            }

            if consecutiveFailures >= 3 {
                let failItem = NSMenuItem(title: "⚠️ Checks failing — try Check Now", action: nil, keyEquivalent: "")
                failItem.isEnabled = false
                menu.addItem(failItem)
            }

            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Check Now", action: #selector(checkNow), keyEquivalent: "c"))
        } else {
            let item = NSMenuItem(title: "Setup not complete", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSetup), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func cleanLogForMenu(_ log: String) -> String {
        var cleaned = log
        if let bracket = cleaned.range(of: "] ") {
            cleaned = String(cleaned[bracket.upperBound...])
        }
        return cleaned
    }

    // MARK: - Actions

    @objc func checkNow() {
        DispatchQueue.global().async {
            AppStateManager.shared.runCheck()
            DispatchQueue.main.async {
                self.buildMenu()
                self.updateMenuBarIcon()
            }
        }
    }

    @objc func showSetup() {
        // If window already exists, just bring it forward
        if let w = setupWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SetupView()
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "nearby"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 420, height: 680))
        window.isMovableByWindowBackground = true
        window.center()
        window.level = .floating
        window.backgroundColor = NSColor.windowBackgroundColor
        window.isReleasedWhenClosed = false
        setupWindow = window

        window.delegate = self

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        setupWindow = nil
        NSApp.setActivationPolicy(.accessory)
        if AppStateManager.shared.isSetUp {
            enableLoginItem()
            startScheduler()
            buildMenu()
            updateMenuBarIcon()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                AppStateManager.shared.runCheck()
            }
        }
    }

    func startScheduler() {
        guard scheduler == nil else { return }
        let s = NSBackgroundActivityScheduler(identifier: "com.nearby.check")
        s.interval = 600
        s.repeats = true
        s.qualityOfService = .utility

        s.schedule { [weak self] completion in
            AppStateManager.shared.runCheck()
            DispatchQueue.main.async {
                self?.trackCheckHealth()
                self?.buildMenu()
                self?.updateMenuBarIcon()
            }
            completion(.finished)
        }
        scheduler = s

        // Backup timer — NSBackgroundActivityScheduler can be deferred by macOS
        // power management. This ensures checks happen at least every 12 minutes.
        if backupTimer == nil {
            backupTimer = Timer.scheduledTimer(withTimeInterval: 720, repeats: true) { [weak self] _ in
                // Only run if the scheduler hasn't fired recently
                let lastCheck = AppStateManager.shared.lastCheckTime ?? .distantPast
                if Date().timeIntervalSince(lastCheck) > 660 {
                    NSLog("nearby: backup timer firing (scheduler was deferred)")
                    DispatchQueue.global().async {
                        AppStateManager.shared.runCheck()
                        DispatchQueue.main.async {
                            self?.trackCheckHealth()
                            self?.buildMenu()
                            self?.updateMenuBarIcon()
                        }
                    }
                }
            }
        }
    }

    /// Track consecutive check failures and update menu bar icon.
    /// A check is healthy if any line shows we read our own GPS (📍) — every
    /// successful check starts with that line. Only checking the LAST line was
    /// wrong: healthy checks often end with ⏱/📱/⏳ lines and were counted as failures.
    func trackCheckHealth() {
        if AppStateManager.shared.lastCheckLog.contains(where: { $0.contains("📍") }) {
            consecutiveFailures = 0
        } else {
            consecutiveFailures += 1
        }
    }

    /// Register as login item so the app auto-starts on reboot.
    func enableLoginItem() {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            if service.status != .enabled {
                do {
                    try service.register()
                    NSLog("nearby: registered as login item")
                } catch {
                    NSLog("nearby: login item registration failed: %@", error.localizedDescription)
                }
            }
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
