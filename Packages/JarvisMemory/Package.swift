// swift-tools-version: 6.0
import PackageDescription

// GRDB.swift + FTS5 arrives in Phase 5; keeping the package dependency-free
// until then so the app builds fast.
let package = Package(
    name: "JarvisMemory",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "JarvisMemory", targets: ["JarvisMemory"])
    ],
    targets: [
        .target(name: "JarvisMemory"),
        .testTarget(name: "JarvisMemoryTests", dependencies: ["JarvisMemory"]),
    ]
)
