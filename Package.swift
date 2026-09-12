// swift-tools-version: 6.2
import PackageDescription

var products: [Product] = [.library(name: "Switch2Kit", targets: ["Switch2Kit"])]
var targets: [Target] = [
    .target(name: "Switch2Kit", path: "Sources/Switch2Kit", swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(name: "Switch2KitTests", dependencies: ["Switch2Kit"], path: "Tests/Switch2KitTests",
                swiftSettings: [.swiftLanguageMode(.v6)])
]
#if os(macOS)
products += [
    .library(name: "Switch2KitExperimental", targets: ["Switch2KitExperimental"]),
    .executable(name: "FinallyTheControllerWorks", targets: ["FinallyTheControllerWorks"]),
    .executable(name: "Switch2KitDemo", targets: ["Switch2KitDemo"])
]
targets += [
    .target(name: "Switch2KitExperimental", dependencies: ["Switch2Kit"], path: "Sources/Switch2KitExperimental",
            swiftSettings: [.swiftLanguageMode(.v6)]),
    .executableTarget(name: "FinallyTheControllerWorks", dependencies: ["Switch2Kit", "Switch2KitExperimental"],
                      path: "Sources/FinallyTheControllerWorks", swiftSettings: [.swiftLanguageMode(.v6)]),
    .executableTarget(name: "Switch2KitDemo", dependencies: ["Switch2Kit"], path: "Examples/Switch2KitDemo",
                      swiftSettings: [.swiftLanguageMode(.v6)])
]
#endif
let package = Package(name: "Switch2Kit", platforms: [.macOS(.v15)], products: products, targets: targets)
