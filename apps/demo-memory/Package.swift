// swift-tools-version: 6.0
//
// Demo Memory's pictures (SPEC-DELTA 6).
//
// `demo-screens` draws the screenshots of Demo Memory's made-up week, the
// list `mci-seed-brain --demo-week --print-screens` prints, and seals each
// one with the capture helper's codec (`MCIKeyframeCodec`), so the window
// opens them exactly as it opens a person's own. `mci-seed-brain
// --demo-week --screens <manifest>` then attaches them to the moments that
// show them. Every word and every pixel is made up; nothing is read from the
// screen, and nothing leaves the Mac.
//
// Targets:
//   - `demo-screens` (executable): the command line the app and the scripts run.
//   - `DemoScreensKit` (library): the screen list, the drawings and the sealing.
//   - `DemoScreensKitTests` (test).
import PackageDescription

let package = Package(
    name: "DemoMemory",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "demo-screens", targets: ["DemoScreens"]),
        .library(name: "DemoScreensKit", targets: ["DemoScreensKit"]),
    ],
    dependencies: [
        .package(path: "../../adapters/macos/MCIKeyframeCodec"),
    ],
    targets: [
        .target(
            name: "DemoScreensKit",
            dependencies: [
                .product(name: "MCIKeyframeCodec", package: "MCIKeyframeCodec"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .executableTarget(
            name: "DemoScreens",
            dependencies: ["DemoScreensKit"],
            path: "Sources/demo-screens",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "DemoScreensKitTests",
            dependencies: [
                "DemoScreensKit",
                .product(name: "MCIKeyframeCodec", package: "MCIKeyframeCodec"),
            ]
        ),
    ]
)
