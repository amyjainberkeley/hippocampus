// swift-tools-version: 6.0
//
// Hippocampus — MCI menu-bar app.
//
// Supervises MCICaptureHelper (Swift) + mci-agent (Rust) as child
// processes, pipes helper stdout → agent stdin. No terminal needed.
//
// Targets:
//   - Hippocampus (executable) — @main App with MenuBarExtra.
//   - HippocampusKit (library)  — ProcessSupervisor, protocols, view models.
//   - HippocampusKitTests (test) — headless tests with fake locators/key stores.
//
// macOS 14+ matches the rest of the MCI app set.
import PackageDescription

let package = Package(
    name: "Hippocampus",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Hippocampus", targets: ["Hippocampus"]),
        .library(name: "HippocampusKit", targets: ["HippocampusKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Hippocampus",
            dependencies: ["HippocampusKit"],
            path: "Sources/Hippocampus",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "HippocampusKit",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/HippocampusKit",
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "HippocampusKitTests",
            dependencies: ["HippocampusKit"],
            path: "Tests/HippocampusKitTests",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ]
)
