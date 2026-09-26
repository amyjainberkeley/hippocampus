// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CaptureOverlapCorpus",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "capture-overlap-corpus", targets: ["CaptureOverlapCorpus"]),
    ],
    targets: [
        .executableTarget(name: "CaptureOverlapCorpus"),
    ]
)
