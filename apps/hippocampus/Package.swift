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

let standaloneFixtureSources = [
    "BriefModelPresenceBehavior.swift",
    "ChildProcessEnvironmentBehavior.swift",
    "KeyCustodyCommandRunnerBehavior.swift",
    "KeyStoreResponsiveness.swift",
    "KeyWrapAuditResponsiveness.swift",
    "RuntimeConfigBehavior.swift",
    "RetentionPreferencesBehavior.swift",
    "SupervisorLifecycleBehavior.swift",
    "SupervisorProcessShutdownBehavior.swift",
    "SupervisorTransitionGateBehavior.swift",
]

let package = Package(
    name: "Hippocampus",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Hippocampus", targets: ["Hippocampus"]),
        .library(name: "HippocampusKit", targets: ["HippocampusKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", exact: "0.6.0"),
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
                .product(name: "TOMLKit", package: "TOMLKit"),
            ],
            path: "Sources/HippocampusKit",
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ],
            linkerSettings: [
                .linkedFramework("Security"),
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
        .executableTarget(
            name: "RuntimeConfigBehavior",
            dependencies: ["HippocampusKit"],
            path: "Tests/Fixtures",
            exclude: standaloneFixtureSources.filter { $0 != "RuntimeConfigBehavior.swift" },
            sources: ["RuntimeConfigBehavior.swift"]
        ),
        .executableTarget(
            name: "SupervisorLifecycleBehavior",
            dependencies: ["HippocampusKit"],
            path: "Tests/Fixtures",
            exclude: standaloneFixtureSources.filter { $0 != "SupervisorLifecycleBehavior.swift" },
            sources: ["SupervisorLifecycleBehavior.swift"]
        ),
        .executableTarget(
            name: "RetentionPreferencesBehavior",
            dependencies: ["HippocampusKit"],
            path: "Tests/Fixtures",
            exclude: standaloneFixtureSources.filter { $0 != "RetentionPreferencesBehavior.swift" },
            sources: ["RetentionPreferencesBehavior.swift"]
        ),
    ]
)
