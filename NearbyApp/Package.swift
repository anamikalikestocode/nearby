// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NearbyApp",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CCryptoShim",
            path: "Sources/CCryptoShim",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "NearbyApp",
            dependencies: ["CCryptoShim"],
            path: "Sources/NearbyApp",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("AppKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("IOKit"),
            ]
        )
    ]
)
