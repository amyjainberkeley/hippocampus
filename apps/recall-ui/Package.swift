// swift-tools-version: 6.0
//
// MCI recall-ui — SwiftUI macOS app (ADR-0016 §6).
//
// Recall and timeline are read-only consumers of the brain. The app links the
// C-ABI FFI shim at `adapters/macos/mci-brain-ffi/`, which opens query handles
// with `SQLITE_OPEN_READ_ONLY`. Explicit Privacy Dashboard delete/wipe actions
// are the only enumerated write escape hatch.
//
// `CMciBrainFFI` wraps the canonical C header. `FFIBrainReader` opens the
// user's brain with the content-free Keychain reference and uses the bundled
// Arctic Embed S Core ML model for hybrid recall. If the model cannot load,
// launch falls back to the compatibility lexical path without weakening the
// read-only boundary.
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
    dependencies: [
        .package(path: "../../adapters/macos/MCIKeyframeCodec"),
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
            dependencies: [
                "CMciBrainFFI",
                .product(name: "MCIKeyframeCodec", package: "MCIKeyframeCodec"),
            ],
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
                .linkedFramework("CoreML"),
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
        .executableTarget(
            name: "ThumbnailProviderBehavior",
            dependencies: [
                "RecallUIKit",
                .product(name: "MCIKeyframeCodec", package: "MCIKeyframeCodec"),
            ],
            path: "Tests/Fixtures",
            exclude: ["DeletionTruthBehavior", "RecallStateBehavior"],
            sources: ["ThumbnailProviderBehavior.swift"]
        ),
        .executableTarget(
            name: "DeletionTruthBehavior",
            dependencies: ["RecallUIKit"],
            path: "Tests/Fixtures/DeletionTruthBehavior"
        ),
        .executableTarget(
            name: "RecallStateBehavior",
            dependencies: ["RecallUIKit"],
            path: "Tests/Fixtures/RecallStateBehavior"
        ),
    ]
)
