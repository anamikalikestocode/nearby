#!/usr/bin/env swift
// locator — get this Mac's GPS coordinates via CoreLocation
// Launched via `open Locator.app`, writes coordinates to a file.

import CoreLocation
import Foundation

class Locator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let outputFile: String

    init(outputFile: String) {
        self.outputFile = outputFile
        super.init()
    }

    func run() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.startUpdatingLocation()

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        // If we got here without writing, write an error
        if !FileManager.default.fileExists(atPath: outputFile) {
            try? "error:timeout".write(toFile: outputFile, atomically: true, encoding: .utf8)
        }
        exit(0)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let coords = "\(loc.coordinate.latitude) \(loc.coordinate.longitude)"
        try? coords.write(toFile: outputFile, atomically: true, encoding: .utf8)
        exit(0)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        try? "error:\(error.localizedDescription)".write(toFile: outputFile, atomically: true, encoding: .utf8)
        exit(1)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            try? "error:denied".write(toFile: outputFile, atomically: true, encoding: .utf8)
            exit(1)
        default:
            break
        }
    }
}

let outputFile = NSHomeDirectory() + "/.nearby/location.txt"
try? FileManager.default.removeItem(atPath: outputFile)
Locator(outputFile: outputFile).run()
