// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "vibenotch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Vibenotch", targets: ["VibenotchApp"]),
        .executable(name: "vibenotch-hook", targets: ["VibenotchHook"]),
        .library(name: "VibenotchCore", targets: ["VibenotchCore"]),
    ],
    targets: [
        .target(
            name: "VibenotchCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "VibenotchApp",
            dependencies: ["VibenotchCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "VibenotchHook",
            dependencies: ["VibenotchCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VibenotchCoreTests",
            dependencies: ["VibenotchCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
