// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MCIKeyframeCodec",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MCIKeyframeCodec", targets: ["MCIKeyframeCodec"]),
        .executable(name: "KeyframeFixtureBuilder", targets: ["KeyframeFixtureBuilder"]),
    ],
    targets: [
        .target(
            name: "MCIKeyframeCodec",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .executableTarget(
            name: "KeyframeCodecBehavior",
            dependencies: ["MCIKeyframeCodec"],
            path: "Tests/Fixtures/KeyframeCodecBehavior"
        ),
        .executableTarget(
            name: "KeyframeFixtureBuilder",
            dependencies: ["MCIKeyframeCodec"]
        ),
        .testTarget(
            name: "MCIKeyframeCodecTests",
            dependencies: ["MCIKeyframeCodec"]
        ),
    ]
)
