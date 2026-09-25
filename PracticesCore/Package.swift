// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PracticesCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PracticesCore", targets: ["PracticesCore"]),
        .executable(name: "practicesctl", targets: ["practicesctl"]),
    ],
    targets: [
        .target(
            name: "PracticesCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "practicesctl",
            dependencies: ["PracticesCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PracticesCoreTests",
            dependencies: ["PracticesCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
