// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JarvisVoice",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "JarvisVoice", targets: ["JarvisVoice"])
    ],
    targets: [
        .target(name: "JarvisVoice"),
        .testTarget(name: "JarvisVoiceTests", dependencies: ["JarvisVoice"]),
    ]
)
