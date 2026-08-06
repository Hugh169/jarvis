// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JarvisAudio",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "JarvisAudio", targets: ["JarvisAudio"])
    ],
    targets: [
        .target(name: "JarvisAudio"),
        .testTarget(name: "JarvisAudioTests", dependencies: ["JarvisAudio"]),
    ]
)
