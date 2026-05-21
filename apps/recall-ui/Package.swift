// swift-tools-version: 6.0
//
// MCI recall-ui — SwiftUI macOS app, Phase 3 P3.9 (ADR-0016 §6).
//
// Read-only consumer of the Phase-3 brain. The app NEVER writes to the
// brain — it links the C-ABI FFI shim at `adapters/macos/mci-brain-ffi/`
// which opens the SQLCipher connection with `SQLITE_OPEN_READ_ONLY`.
//
// P3.9a (this PR): SwiftUI app + view models + `BrainReader` protocol
// with a Swift-side `StubBrainReader` (canned demo data) so the views
// have something to render and the unit tests can run headlessly. The
// `FFIBrainReader` adapter that calls into mci-brain-ffi is scaffolded
// but not yet linked to the static lib — that's P3.9b.
//
// Targets:
//   - `recall-ui` (executable) — the @main App with the SwiftUI scenes.
//   - `RecallUIKit` (library)  — view models, BrainReader protocol,
//     reason-string mapper, snippet formatter; the testable surface.
//   - `RecallUIKitTests` (test) — unit tests on the view models +
//     reason-string map.
//
// macOS 14+ deployment target matches the rest of the MCI app set
// (MCICaptureHelper Package.swift, ADR-0013/0015 minimums).
import PackageDescription

let package = Package(
    name: "recall-ui",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "recall-ui", targets: ["RecallUI"]),
        .library(name: "RecallUIKit", targets: ["RecallUIKit"]),
    ],
    targets: [
        .executableTarget(
            name: "RecallUI",
            dependencies: ["RecallUIKit"],
            path: "Sources/RecallUI",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "RecallUIKit",
            path: "Sources/RecallUIKit",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "RecallUIKitTests",
            dependencies: ["RecallUIKit"],
            path: "Tests/RecallUIKitTests"
        ),
    ]
)
