// swift-tools-version: 6.0
//
// hippocampus-mind: the on-device model process.
//
// The agent (and Recall) start it as a child and exchange JSON lines over
// stdin/stdout, the same shape as the OCR worker. It answers with Apple's
// Foundation Models on macOS 26, or with a model server on this Mac (Ollama,
// LM Studio) on any Mac from macOS 14 (`EngineChoice`). FoundationModels is
// linked weakly, so the binary built with the macOS 26 SDK still launches on
// macOS 14. Nothing it reads or writes leaves the Mac.
//
// Targets:
//   - `MindKit` (library): the wire protocol, the serve loop, prompts and the
//     engines.
//   - `hippocampus-mind` (executable): the serve loop over the chosen engine.
//   - `MindKitTests`: protocol, prompt and engine tests with a fake engine and
//     a fake model server on 127.0.0.1; a live Foundation Models probe runs
//     only with MCI_LIVE_MIND=1.
//   - `SlowMindServe` (test fixture, never shipped): the serve loop over an
//     engine that takes a minute per request, run by `ServeLoopTests`.
//
// To build and test as on a Mac without Foundation Models:
//   swift test -Xswiftc -DMIND_NO_FOUNDATION_MODELS

import PackageDescription

let package = Package(
    name: "mind",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "hippocampus-mind", targets: ["hippocampus-mind"]),
        .library(name: "MindKit", targets: ["MindKit"]),
    ],
    targets: [
        .target(name: "MindKit", path: "Sources/MindKit"),
        .executableTarget(name: "hippocampus-mind", dependencies: ["MindKit"], path: "Sources/hippocampus-mind"),
        .testTarget(name: "MindKitTests", dependencies: ["MindKit"], path: "Tests/MindKitTests"),
        .executableTarget(name: "SlowMindServe", dependencies: ["MindKit"], path: "Tests/Fixtures/SlowMindServe"),
    ]
)
