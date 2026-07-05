// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Qwen3TTSPoc",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "Qwen3TTSPoc",
            targets: ["Qwen3TTSPoc"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/hamptus/mlx-swift-qwen3-tts", from: "0.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "Qwen3TTSPoc",
            dependencies: [
                .product(name: "Qwen3TTS", package: "mlx-swift-qwen3-tts"),
            ]
        ),
        .testTarget(
            name: "Qwen3TTSPocTests",
            dependencies: ["Qwen3TTSPoc"]
        ),
    ]
)
