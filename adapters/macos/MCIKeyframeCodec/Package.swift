// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MCIKeyframeCodec",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MCIKeyframeCodec", targets: ["MCIKeyframeCodec"]),
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
        .testTarget(
            name: "MCIKeyframeCodecTests",
            dependencies: ["MCIKeyframeCodec"]
        ),
    ]
)
