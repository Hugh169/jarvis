// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JarvisBrain",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "JarvisBrain", targets: ["JarvisBrain"])
    ],
    dependencies: [
        .package(path: "../JarvisTools")
    ],
    targets: [
        .target(name: "JarvisBrain", dependencies: ["JarvisTools"]),
        .testTarget(name: "JarvisBrainTests", dependencies: ["JarvisBrain"]),
    ]
)
