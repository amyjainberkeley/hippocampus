// swift-tools-version: 6.0
//
// Hippocampus setup — SwiftUI macOS app: four screens (Welcome,
// Permissions, Promise, Try it) and the panels the app opens by route.
//
// Targets:
//   - `Onboarding` (executable) — the @main entry point, the window and
//     the screens.
//   - `OnboardingKit` (library) — view models, copy, stores and the
//     permission protocols (TCCPermission, AllowlistStore, RetentionStore).
//     Headless-testable.
//   - `OnboardingKitTests` (test) — unit tests on view models + protocol stubs.
//
// macOS 14+ deployment target matches the rest of the MCI app set.
// Zero external dependencies (ADR-0008 dep gate).

import PackageDescription

let package = Package(
    name: "onboarding",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "onboarding", targets: ["Onboarding"]),
        .library(name: "OnboardingKit", targets: ["OnboardingKit"]),
    ],
    targets: [
        .executableTarget(
            name: "Onboarding",
            dependencies: ["OnboardingKit"],
            path: "Sources/Onboarding",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "OnboardingKit",
            path: "Sources/OnboardingKit",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "OnboardingKitTests",
            dependencies: ["OnboardingKit"],
            path: "Tests/OnboardingKitTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
        .executableTarget(
            name: "RetentionPersistenceBehavior",
            dependencies: ["OnboardingKit"],
            path: "Tests/Fixtures/RetentionPersistenceBehavior"
        ),
        .executableTarget(
            name: "OnboardingRouteBehavior",
            dependencies: ["OnboardingKit"],
            path: "Tests/Fixtures/OnboardingRouteBehavior"
        ),
        .executableTarget(
            name: "AppAccessBehavior",
            dependencies: ["OnboardingKit"],
            path: "Tests/Fixtures/AppAccessBehavior"
        ),
        .executableTarget(
            name: "AIToolConnectorBehavior",
            dependencies: ["OnboardingKit"],
            path: "Tests/Fixtures/AIToolConnectorBehavior"
        ),
    ]
)
