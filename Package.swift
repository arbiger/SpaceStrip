// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpaceStrip",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SpaceStrip", targets: ["SpaceStrip"])
    ],
    targets: [
        .executableTarget(
            name: "SpaceStrip",
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
