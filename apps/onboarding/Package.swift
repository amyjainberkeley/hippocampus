// swift-tools-version: 6.0
//
// MCI onboarding — SwiftUI macOS app, Phase 4 P4.2 (ADR-0017 §2).
//
// 5-step TCC walkthrough + "What MCI Sees" trust panel + retention
// policy UI scaffold. Protocol stubs for TCC probing — real wiring
// lands in a follow-on PR.
//
// Targets:
//   - `Onboarding` (executable) — the @main App with NavigationStack flow.
//   - `OnboardingKit` (library) — view models, protocols (TCCPermission,
//     AllowlistStore, RetentionStore), cascade diagram model. Headless-testable.
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
    ]
)
