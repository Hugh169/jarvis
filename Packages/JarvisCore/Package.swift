// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JarvisCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "JarvisCore", targets: ["JarvisCore"])
    ],
    targets: [
        .target(name: "JarvisCore"),
        .testTarget(name: "JarvisCoreTests", dependencies: ["JarvisCore"]),
    ]
)
