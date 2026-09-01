// swift-tools-version: 6.0
//
// MCI macOS capture helper — Package.swift
//
// Phase 1 cycle 1 (Director-Recording, CSO sign-off). Per ADR-0002 (stack
// split) + ADR-0007 (separate signed Swift helper process). The Swift helper
// owns the SCStream lifecycle, runs the ADR-0013 sensitive-surface
// suppression cascade before any frame/metadata crosses IPC, and retains
// only post-OCR, condensed, authenticated evidence.
//
// macOS 14+ deployment target — ScreenCaptureKit needs 12.3+, but the
// suppression cascade prefers the modern SCContentFilter exclusion APIs
// that stabilized in 14.
import PackageDescription

let package = Package(
    name: "MCICaptureHelper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "mci-capture-helper", targets: ["MCICaptureHelper"]),
        .library(name: "MCICaptureHelperKit", targets: ["MCICaptureHelperKit"]),
    ],
    dependencies: [
        .package(path: "../MCIKeyframeCodec"),
    ],
    targets: [
        .executableTarget(
            name: "MCICaptureHelper",
            dependencies: ["MCICaptureHelperKit"],
            path: "Sources/MCICaptureHelper",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "MCICaptureHelperKit",
            dependencies: [
                .product(name: "MCIKeyframeCodec", package: "MCIKeyframeCodec"),
            ],
            path: "Sources/MCICaptureHelperKit",
            resources: [
                // ADR-0013 §3 + ADR-0015 §5 + ADR-0017 §3.1 — CSO-ratified
                // known-safe-apps allowlist. Lives in the signed bundle's
                // Resources (NOT user-writable in v1 per ADR-0017 §3.1);
                // loaded at helper startup via `Bundle.module`. `.copy`
                // (not `.process`) — the TOML is a verbatim trust
                // artifact, no SwiftPM transformation desired.
                .copy("Resources/known-safe-apps.toml"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ],
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "MCICaptureHelperKitTests",
            dependencies: [
                "MCICaptureHelperKit",
                .product(name: "MCIKeyframeCodec", package: "MCIKeyframeCodec"),
            ],
            path: "Tests/MCICaptureHelperKitTests"
        ),
        .executableTarget(
            name: "Task4CaptureBehavior",
            dependencies: ["MCICaptureHelperKit"],
            path: "Tests/Fixtures/Task4CaptureBehavior"
        ),
    ]
)
