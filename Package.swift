// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CopilotBridge",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CopilotBridge", targets: ["CopilotBridge"])
    ],
    targets: [
        .executableTarget(
            name: "CopilotBridge",
            path: "Sources/CopilotBridge",
            resources: [],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
