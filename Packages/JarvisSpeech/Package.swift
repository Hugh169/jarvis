// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JarvisSpeech",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "JarvisSpeech", targets: ["JarvisSpeech"])
    ],
    targets: [
        .target(name: "JarvisSpeech"),
        .testTarget(name: "JarvisSpeechTests", dependencies: ["JarvisSpeech"]),
    ]
)
