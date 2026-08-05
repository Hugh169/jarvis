// swift-tools-version: 6.0
// Convenience manifest: builds the app sources as a plain executable
// (`swift run JarvisDev`) for a fast loop without producing a bundle. The real
// app — entitlements, Info.plist, TCC permissions — is the Xcode target
// generated from project.yml.
//
// REQUIRES FULL XCODE. SwiftUI's @State/#Preview are macros whose plugins
// (SwiftUIMacros, PreviewsMacros) ship only with Xcode, not the Command Line
// Tools, so no SwiftUI target compiles under a CLT-only toolchain. The
// Packages/ below have no SwiftUI dependency and build and test fine on CLT
// alone — see scripts/test.sh.
import PackageDescription

let package = Package(
    name: "JarvisDev",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "Packages/JarvisCore"),
        .package(path: "Packages/JarvisAudio"),
        .package(path: "Packages/JarvisSpeech"),
        .package(path: "Packages/JarvisVoice"),
        .package(path: "Packages/JarvisBrain"),
        .package(path: "Packages/JarvisTools"),
        .package(path: "Packages/JarvisMemory"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "JarvisDev",
            dependencies: [
                "JarvisCore", "JarvisAudio", "JarvisSpeech", "JarvisVoice",
                "JarvisBrain", "JarvisTools", "JarvisMemory",
                "KeyboardShortcuts",
            ],
            path: "Jarvis"
        )
    ]
)
