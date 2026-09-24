// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "dctt",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "dctt", targets: ["DcttApp"]),
               .executable(name: "dctt-check", targets: ["DcttCheck"])],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.16.1", traits: []),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", exact: "3.1.0")
    ],
    targets: [
        .target(name: "DcttCore", dependencies: [
            .product(name: "WhisperKit", package: "argmax-oss-swift"),
            .product(name: "FluidAudio", package: "FluidAudio")
        ], resources: [.copy("Resources/models.json")]),
        .executableTarget(name: "DcttApp", dependencies: ["DcttCore",
            .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")]),
        .executableTarget(name: "DcttCheck", dependencies: ["DcttCore"]),
        .testTarget(name: "DcttCoreTests", dependencies: ["DcttCore"])
    ],
    swiftLanguageModes: [.v5]
)
