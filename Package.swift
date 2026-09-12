// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ps2mc",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ps2mc", targets: ["ps2mc"]),
        .executable(name: "PS2MCApp", targets: ["PS2MCApp"]),
        .library(name: "PS2MCKit", targets: ["PS2MCKit"]),
    ],
    targets: [
        // Shared engine: HID decoding, bindings, event synthesis. No UI, no CLI.
        .target(
            name: "PS2MCKit",
            path: "Sources/PS2MCKit",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "ps2mc",
            dependencies: ["PS2MCKit"],
            path: "Sources/ps2mc",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PS2MCApp",
            dependencies: ["PS2MCKit"],
            path: "Sources/PS2MCApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
