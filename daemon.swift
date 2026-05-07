#!/usr/bin/env swift
// daemon.swift — persistent nearby checker that runs during macOS maintenance wakes
// Uses NSBackgroundActivityScheduler (Apple's official API for background tasks)
// This runs even when the lid is closed — during DarkWake maintenance windows.

import Foundation

class NearbyDaemon {
    private let scheduler = NSBackgroundActivityScheduler(identifier: "com.nearby.check")
    private let nearbyScript: String

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.nearbyScript = "\(home)/.nearby/nearby.py"
    }

    func start() {
        // Schedule proximity checks every 10 minutes
        // During sleep, macOS fires this during maintenance wakes (~every 15-60 min)
        // While awake, it fires closer to the requested interval
        scheduler.interval = 600  // 10 minutes
        scheduler.repeats = true
        scheduler.qualityOfService = .utility

        scheduler.schedule { [weak self] completion in
            guard let self = self else {
                completion(.finished)
                return
            }
            self.runCheck()
            completion(.finished)
        }

        // Also run immediately on launch
        runCheck()

        // Keep the process alive
        RunLoop.current.run()
    }

    private func runCheck() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = [nearbyScript]

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            NSLog("nearby: failed to run check — \(error)")
        }
    }
}

NearbyDaemon().start()
