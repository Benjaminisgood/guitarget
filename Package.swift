// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Guitarget",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GuitarCore", targets: ["GuitarCore"]),
        .library(name: "GuitarAudio", targets: ["GuitarAudio"]),
        .executable(name: "Guitarget", targets: ["Guitarget"])
    ],
    targets: [
        .target(name: "GuitarCore"),
        // DSP must meet the render deadline even while SwiftUI remains easy to debug.
        .target(name: "GuitarAudio", dependencies: ["GuitarCore"], swiftSettings: [
            .unsafeFlags(["-O"], .when(configuration: .debug))
        ]),
        .executableTarget(name: "Guitarget", dependencies: ["GuitarCore", "GuitarAudio"]),
        .testTarget(name: "GuitarCoreTests", dependencies: ["GuitarCore"]),
        .testTarget(name: "GuitarAudioTests", dependencies: ["GuitarAudio", "GuitarCore"])
    ],
    swiftLanguageModes: [.v5]
)
