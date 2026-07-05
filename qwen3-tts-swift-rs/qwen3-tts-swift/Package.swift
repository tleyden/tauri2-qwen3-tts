// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "qwen3-tts-swift",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "qwen3-tts-swift",
            type: .static,
            targets: ["qwen3-tts-swift"]
        ),
    ],
    dependencies: [
        .package(name: "SwiftRs", url: "https://github.com/Brendonovich/swift-rs", from: "1.0.6"),
        .package(url: "https://github.com/hamptus/mlx-swift-qwen3-tts", from: "0.2.0"),
    ],
    targets: [
        .target(
            name: "qwen3-tts-swift",
            dependencies: [
                .product(name: "SwiftRs", package: "SwiftRs"),
                .product(name: "Qwen3TTS", package: "mlx-swift-qwen3-tts"),
            ]
        ),
    ]
)
