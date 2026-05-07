import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var setupWindow: NSWindow?
    var scheduler: NSBackgroundActivityScheduler?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create menu bar item FIRST, then hide from dock
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = " nearby"
            if let img = NSImage(systemSymbolName: "location.fill", accessibilityDescription: "nearby") {
                img.size = NSSize(width: 16, height: 16)
                img.isTemplate = true
                button.image = img
                button.imagePosition = .imageLeading
            }
        }

        NSApp.setActivationPolicy(.accessory)

        buildMenu()

        if AppStateManager.shared.isSetUp {
            startScheduler()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                AppStateManager.shared.runCheck()
            }
        } else {
            showSetup()
        }
    }

    func buildMenu() {
        let menu = NSMenu()

        if AppStateManager.shared.isSetUp {
            let friends = AppStateManager.shared.state.friends
            let statusTitle = "\(friends.count) friends tracked"
            let item = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)

            if let lastLog = AppStateManager.shared.lastCheckLog.last {
                let logItem = NSMenuItem(title: lastLog, action: nil, keyEquivalent: "")
                logItem.isEnabled = false
                menu.addItem(logItem)
            }

            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Check Now", action: #selector(checkNow), keyEquivalent: "c"))
        }

        menu.addItem(NSMenuItem(title: "Setup...", action: #selector(showSetup), keyEquivalent: "s"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit nearby", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc func checkNow() {
        DispatchQueue.global().async {
            AppStateManager.shared.runCheck()
            DispatchQueue.main.async { self.buildMenu() }
        }
    }

    @objc func showSetup() {
        if setupWindow == nil {
            let view = SetupView()
            let hostingController = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "nearby"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 400, height: 560))
            window.isMovableByWindowBackground = true
            window.center()
            setupWindow = window

            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                if AppStateManager.shared.isSetUp {
                    self?.startScheduler()
                    self?.buildMenu()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        AppStateManager.shared.runCheck()
                    }
                }
            }
        }
        setupWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func startScheduler() {
        guard scheduler == nil else { return }
        let s = NSBackgroundActivityScheduler(identifier: "com.nearby.check")
        s.interval = 600  // 10 minutes
        s.repeats = true
        s.qualityOfService = .utility

        s.schedule { [weak self] completion in
            AppStateManager.shared.runCheck()
            DispatchQueue.main.async { self?.buildMenu() }
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
