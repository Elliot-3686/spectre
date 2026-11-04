// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpectreCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SpectreCore", targets: ["SpectreCore"]),
    ],
    targets: [
        // Lock-free single-producer / single-consumer ring buffer written in C11
        // (stdatomic) so the real-time audio callback never locks or allocates.
        .target(name: "CSpectreRing"),
        .target(name: "SpectreCore", dependencies: ["CSpectreRing"]),
        .testTarget(name: "SpectreCoreTests", dependencies: ["SpectreCore"]),
    ]
)
