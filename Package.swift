// swift-tools-version: 6.2
// GameCubed — Switch 2 controllers on macOS.
import PackageDescription

let package = Package(
    name: "GameCubed",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "GameCubed",
            path: "Sources/GameCubed",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
