// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CodePilot",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "CodePilotCore",
            targets: ["CodePilotCore"]
        ),
        .executable(
            name: "CodePilot",
            targets: ["CodePilot"]
        )
    ],
    targets: [
        .target(
            name: "CodePilotCore",
            path: "Sources/CodePilotCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "CodePilot",
            dependencies: ["CodePilotCore"],
            path: "Sources/CodePilot"
        ),
        .testTarget(
            name: "CodePilotTests",
            dependencies: ["CodePilotCore"],
            path: "Tests/CodePilotTests"
        )
    ]
)
