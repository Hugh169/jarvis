// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JarvisConnectors",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "JarvisConnectors", targets: ["JarvisConnectors"])
    ],
    dependencies: [
        .package(path: "../JarvisCore"),
        .package(path: "../JarvisTools"),
    ],
    targets: [
        .target(
            name: "JarvisConnectors",
            dependencies: ["JarvisCore", "JarvisTools"]
        ),
        .testTarget(name: "JarvisConnectorsTests", dependencies: ["JarvisConnectors"]),
    ]
)
