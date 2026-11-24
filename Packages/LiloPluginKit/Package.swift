// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiloPluginKit",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "PluginCore", targets: ["PluginCore"]),
        .library(name: "TestingSupport", targets: ["TestingSupport"])
    ],
    targets: [
        // Foundation only: no AppKit, no WebKit, so `swift test` here runs headless on a Mac or a VPS.
        .target(name: "PluginCore"),
        .target(name: "TestingSupport", dependencies: ["PluginCore"]),
        .testTarget(name: "PluginCoreTests", dependencies: ["PluginCore", "TestingSupport"], path: "Tests/PluginCoreTests")
    ]
)
