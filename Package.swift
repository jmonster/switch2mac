// swift-tools-version: 6.0
// "Finally the Controller Works" — Switch 2 controllers on macOS, for real.
import PackageDescription

let package = Package(
    name: "FinallyTheControllerWorks",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "FinallyTheControllerWorks",
            path: "Sources/FinallyTheControllerWorks",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
