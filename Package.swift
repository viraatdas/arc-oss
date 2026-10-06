// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Radian",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Radian", targets: ["Radian"]),
        .library(name: "RadianCore", targets: ["RadianCore"]),
    ],
    targets: [
        // Model, persistence and importers. No AppKit, so it is fully unit-testable.
        .target(name: "RadianCore"),
        .executableTarget(
            name: "Radian",
            dependencies: ["RadianCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "RadianCoreTests", dependencies: ["RadianCore"]),
    ]
)
