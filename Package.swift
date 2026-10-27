// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "lookaway",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "lookaway", targets: ["lookaway"]),
    ],
    targets: [
        // Pure logic: the away/present state machine, settings and match calibration.
        // No AppKit, AVFoundation or Vision, so it is trivially testable.
        .target(name: "LookawayCore"),
        // The menu-bar app: camera, Vision, lock, UI.
        .executableTarget(
            name: "lookaway",
            dependencies: ["LookawayCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LookawayCoreTests",
            dependencies: ["LookawayCore"]
        ),
    ]
)
