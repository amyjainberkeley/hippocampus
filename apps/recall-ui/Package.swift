// swift-tools-version: 6.0
//
// MCI recall-ui — SwiftUI macOS app, Phase 3 P3.9 (ADR-0016 §6).
//
// Read-only consumer of the Phase-3 brain. The app NEVER writes to the
// brain — it links the C-ABI FFI shim at `adapters/macos/mci-brain-ffi/`
// which opens the SQLCipher connection with `SQLITE_OPEN_READ_ONLY`.
//
// # P3.9 sequence
//
// - P3.9a (PR #78): SwiftUI app + view models + `BrainReader` protocol with
//   a Swift-side `StubBrainReader` (canned demo data) so the views had
//   something to render and the unit tests ran headlessly. The FFI shim
//   was scaffolded with stub bodies; the Swift side never linked it.
//
// - **P3.9b (this PR)**: FFI bodies wired to the real read-only
//   `SqlCipherBrainStore` + FTS5 search. New `CMciBrainFFI` system-library
//   target wraps the canonical C header so Swift can `import CMciBrainFFI`;
//   new `FFIBrainReader` Swift type adapts the C ABI to the `BrainReader`
//   protocol; the executable target wires `FFIBrainReader` against
//   `~/Library/Application Support/MCI/mci.sqlite` using the bundled
//   executable's file-Keychain ACL and content-free service/account reference.
//
// # Build precondition
//
// The CMciBrainFFI target's modulemap links `libmci_brain_ffi.a`. Use the
// repository wrapper for every build/test so Cargo's matching profile is
// staged into this package before SwiftPM links:
//
//     ../../scripts/swift-package.sh build --package-path .
//     ../../scripts/swift-package.sh build -c release --package-path .
//
// Targets:
//   - `recall-ui` (executable) — the @main App with the SwiftUI scenes.
//   - `RecallUIKit` (library)  — view models, BrainReader protocol,
//     reason-string mapper, snippet formatter, `FFIBrainReader` adapter.
//   - `CMciBrainFFI` (systemLibrary) — module wrapper around the Rust
//     FFI C ABI; declares `link "mci_brain_ffi"` so SwiftPM passes
//     `-lmci_brain_ffi` to the linker.
//   - `RecallUIKitTests` (test) — unit tests on the view models +
//     reason-string map + FFIBrainReader lifecycle/error paths.
//
// macOS 14+ deployment target matches the rest of the MCI app set.
import PackageDescription

let package = Package(
    name: "recall-ui",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "recall-ui", targets: ["RecallUI"]),
        .library(name: "RecallUIKit", targets: ["RecallUIKit"]),
    ],
    targets: [
        // System-library wrapper around the Rust FFI's C header + static lib.
        // The link directive in module.modulemap adds `-lmci_brain_ffi`; the
        // `-L` search path is added by the consumer's linkerSettings.
        .systemLibrary(
            name: "CMciBrainFFI",
            path: "Sources/CMciBrainFFI"
        ),
        .executableTarget(
            name: "RecallUI",
            dependencies: ["RecallUIKit"],
            path: "Sources/RecallUI",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ],
            linkerSettings: [
                .unsafeFlags(
                    ["-L.build/mci-brain-ffi/debug"],
                    .when(configuration: .debug)
                ),
                .unsafeFlags(
                    ["-L.build/mci-brain-ffi/release"],
                    .when(configuration: .release)
                ),
            ]
        ),
        .target(
            name: "RecallUIKit",
            dependencies: ["CMciBrainFFI"],
            path: "Sources/RecallUIKit",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ],
            linkerSettings: [
                .unsafeFlags(
                    ["-L.build/mci-brain-ffi/debug"],
                    .when(configuration: .debug)
                ),
                .unsafeFlags(
                    ["-L.build/mci-brain-ffi/release"],
                    .when(configuration: .release)
                ),
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "RecallUIKitTests",
            dependencies: ["RecallUIKit"],
            path: "Tests/RecallUIKitTests",
            linkerSettings: [
                .unsafeFlags(
                    ["-L.build/mci-brain-ffi/debug"],
                    .when(configuration: .debug)
                ),
                .unsafeFlags(
                    ["-L.build/mci-brain-ffi/release"],
                    .when(configuration: .release)
                ),
            ]
        ),
    ]
)
