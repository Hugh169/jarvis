// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JarvisTools",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "JarvisTools", targets: ["JarvisTools"])
    ],
    dependencies: [
        // For the HUD presentation models (Schedule, ToolActivity). JarvisCore
        // has no dependency of its own, so this stays acyclic.
        .package(path: "../JarvisCore")
    ],
    targets: [
        .target(name: "JarvisTools", dependencies: ["JarvisCore"]),
        .testTarget(name: "JarvisToolsTests", dependencies: ["JarvisTools"]),
    ]
)
