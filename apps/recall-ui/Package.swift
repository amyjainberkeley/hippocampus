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
//   `~/Library/Application Support/MCI/mci.sqlite` (key from env var
//   `MCI_DB_KEY_HEX` for the demo, with a clear TODO for Keychain
//   integration).
//
// # Build precondition
//
// The CMciBrainFFI target's modulemap links `libmci_brain_ffi.a`. That
// static library is produced by Cargo at workspace `target/<profile>/`,
// NOT by SwiftPM. Before `swift build` / `swift test`:
//
//     cargo build -p mci-brain-ffi              # debug
//     cargo build -p mci-brain-ffi --release    # release
//
// The `linkerSettings` below add `-L../../target/debug` (and
// `-L../../target/release`) so the linker can find the static lib. Paths
// are relative to this package directory (`apps/recall-ui/`).
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
                // Cargo writes libmci_brain_ffi.a to <workspace>/target/<profile>.
                // Both -L paths are listed so debug and release builds find it
                // (SwiftPM doesn't expose configuration-conditional unsafeFlags
                // for linkerSettings before sw-tools 6.0; both are inert when
                // empty so this is safe).
                .unsafeFlags(["-L../../target/debug"]),
                .unsafeFlags(["-L../../target/release"]),
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
                .unsafeFlags(["-L../../target/debug"]),
                .unsafeFlags(["-L../../target/release"]),
            ]
        ),
        .testTarget(
            name: "RecallUIKitTests",
            dependencies: ["RecallUIKit"],
            path: "Tests/RecallUIKitTests",
            linkerSettings: [
                .unsafeFlags(["-L../../target/debug"]),
                .unsafeFlags(["-L../../target/release"]),
            ]
        ),
    ]
)
