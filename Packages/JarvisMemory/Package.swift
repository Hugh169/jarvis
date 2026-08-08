// swift-tools-version: 6.0
import PackageDescription

// FTS5 comes from the system SQLite, not GRDB — see "Known deviations from the
// spec" in CLAUDE.md. The only dependency here is a sibling package.
let package = Package(
    name: "JarvisMemory",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "JarvisMemory", targets: ["JarvisMemory"])
    ],
    dependencies: [
        // For the JarvisTool protocol the memory tools conform to. Same shape
        // as JarvisConnectors, which owns its own tools for the same reason.
        .package(path: "../JarvisTools"),
    ],
    targets: [
        .target(name: "JarvisMemory", dependencies: ["JarvisTools"]),
        .testTarget(name: "JarvisMemoryTests", dependencies: ["JarvisMemory"]),
    ]
)
