// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PracticesCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PracticesCore", targets: ["PracticesCore"]),
        .executable(name: "practicesctl", targets: ["practicesctl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
    ],
    targets: [
        .target(
            name: "PracticesCore",
            dependencies: ["Yams"],
            resources: [.copy("Runtime/python"), .copy("Resources/AgentInstructions.md"), .copy("Resources/CodingRules.md"), .copy("Resources/Conventions.md"), .copy("Resources/templates")],
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
