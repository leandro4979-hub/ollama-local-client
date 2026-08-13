// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OllamaLocalClient",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OllamaLocalCore", targets: ["OllamaLocalCore"]),
        .executable(name: "ollama-local", targets: ["OllamaLocalCLI"])
    ],
    targets: [
        .target(name: "OllamaLocalCore"),
        .executableTarget(name: "OllamaLocalCLI", dependencies: ["OllamaLocalCore"]),
        .testTarget(name: "OllamaLocalCoreTests", dependencies: ["OllamaLocalCore"])
    ]
)
