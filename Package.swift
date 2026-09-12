// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Switch2Kit",
    platforms: [.macOS(.v15)],
    products: [.library(name: "Switch2Kit", targets: ["Switch2Kit"])],
    targets: [
        .target(name: "Switch2Kit", swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "FinallyTheControllerWorks", path: "Sources/FinallyTheControllerWorks",
                          swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "Switch2KitTests", dependencies: ["Switch2Kit"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
