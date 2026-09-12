// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ps2mc",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ps2mc", targets: ["ps2mc"])
    ],
    targets: [
        .executableTarget(
            name: "ps2mc",
            path: "Sources/ps2mc",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("AppKit")
            ]
        )
    ]
)
