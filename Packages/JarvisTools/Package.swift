// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JarvisTools",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "JarvisTools", targets: ["JarvisTools"])
    ],
    targets: [
        .target(name: "JarvisTools"),
        .testTarget(name: "JarvisToolsTests", dependencies: ["JarvisTools"]),
    ]
)
