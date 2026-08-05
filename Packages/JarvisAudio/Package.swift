// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JarvisAudio",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "JarvisAudio", targets: ["JarvisAudio"])
    ],
    targets: [
        .target(name: "JarvisAudio"),
        .testTarget(name: "JarvisAudioTests", dependencies: ["JarvisAudio"]),
    ]
)
