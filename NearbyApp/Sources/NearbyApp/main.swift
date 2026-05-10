import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    var setupWindow: NSWindow?
    var scheduler: NSBackgroundActivityScheduler?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarIcon()
        buildMenu()

        Telemetry.trackAppLaunch()

        if AppStateManager.shared.isSetUp {
            startScheduler()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                AppStateManager.shared.runCheck()
                DispatchQueue.main.async { self.buildMenu() }
            }
        }

        showSetup()
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
                    let staleItem = NSMenuItem(title: "Searching... (last check \(ago)m ago)", action: nil, keyEquivalent: "")
                    staleItem.isEnabled = false
                    menu.addItem(staleItem)
                }
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
                self?.buildMenu()
                self?.updateMenuBarIcon()
            }
            completion(.finished)
        }
        scheduler = s
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
