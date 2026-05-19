// swift-tools-version: 6.0
//
// MCI macOS capture helper — Package.swift
//
// Phase 1 cycle 1 (Director-Recording, CSO sign-off). Per ADR-0002 (stack
// split) + ADR-0007 (separate signed Swift helper process). The Swift helper
// owns the SCStream lifecycle, runs the ADR-0013 sensitive-surface
// suppression cascade BEFORE any frame/metadata crosses IPC, and ships the
// HEVC keyframe encode via VideoToolbox.
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
            path: "Sources/MCICaptureHelperKit",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "MCICaptureHelperKitTests",
            dependencies: ["MCICaptureHelperKit"],
            path: "Tests/MCICaptureHelperKitTests"
        ),
    ]
)
