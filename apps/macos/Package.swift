// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PiGUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PiCore", targets: ["PiCore"]),
        .executable(name: "PiGUI", targets: ["PiGUI"]),
    ],
    targets: [
        // Foundation-only core: pi CLI driver, session parsing, git plumbing.
        // Deliberately free of AppKit/SwiftUI so it stays testable headlessly.
        .target(name: "PiCore"),
        .executableTarget(name: "PiGUI", dependencies: ["PiCore"]),
        .testTarget(
            name: "PiCoreTests",
            dependencies: ["PiCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
