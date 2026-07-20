// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "rocky",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Rocky", targets: ["RockyApp"]),
        .executable(name: "rocky-hook", targets: ["RockyHook"]),
        .library(name: "RockyCore", targets: ["RockyCore"]),
    ],
    targets: [
        .target(
            name: "RockyCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "RockyApp",
            dependencies: ["RockyCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "RockyHook",
            dependencies: ["RockyCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RockyCoreTests",
            dependencies: ["RockyCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
