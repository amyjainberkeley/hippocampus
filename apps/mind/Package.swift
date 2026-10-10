// swift-tools-version: 6.0
//
// hippocampus-mind: the on-device model process.
//
// The agent (and Recall) start it as a child and exchange JSON lines over
// stdin/stdout, the same shape as the OCR worker. It uses Apple's Foundation
// Models framework, so it is built for macOS 26; on an older Mac the binary
// does not launch and callers treat understanding as unavailable, falling
// back to deterministic summaries. Nothing it reads or writes leaves the Mac.
//
// Targets:
//   - `MindKit` (library): the wire protocol, prompts and the engine seam.
//   - `hippocampus-mind` (executable): the serve loop over a real engine.
//   - `MindKitTests`: protocol and prompt tests with a fake engine; a live
//     Foundation Models probe runs only with MCI_LIVE_MIND=1.

import PackageDescription

let package = Package(
    name: "mind",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "hippocampus-mind", targets: ["hippocampus-mind"]),
        .library(name: "MindKit", targets: ["MindKit"]),
    ],
    targets: [
        .target(name: "MindKit", path: "Sources/MindKit"),
        .executableTarget(name: "hippocampus-mind", dependencies: ["MindKit"], path: "Sources/hippocampus-mind"),
        .testTarget(name: "MindKitTests", dependencies: ["MindKit"], path: "Tests/MindKitTests"),
    ]
)
