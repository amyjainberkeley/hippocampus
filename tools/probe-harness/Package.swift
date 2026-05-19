// swift-tools-version: 6.0
//
// MCI probe-harness — STEP-2-FINDING-001 isolation test app.
//
// A tiny standalone Cocoa Swift app with one window and one
// `NSSecureTextField`. The harness is NOT part of the shipping
// `mci-capture-helper`; it exists solely to give STEP-2-FINDING-001
// re-verification a §3-free §4 surface. See `README.md` for the full
// isolation rationale.
//
// Built locally only — not signed, not notarized, not distributed.
// `swift build` from `tools/probe-harness/` produces an executable
// the human operator can launch alongside the helper while running
// `mci-capture-helper --capture --probe-debug`.

import PackageDescription

let package = Package(
    name: "ProbeHarness",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ProbeHarness",
            path: "Sources/ProbeHarness"
        )
    ]
)
