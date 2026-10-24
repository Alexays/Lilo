// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lilo",
    platforms: [
        .macOS("26.0")
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "Lilo",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sparkle", package: "Sparkle"),
                "GhosttyVt"
            ],
            path: "Lilo",
            exclude: [
                "Info.plist",
                "Extensions/bridge-src",
                "Lilo.entitlements",
                "Lilo.Debug.entitlements",
                // Compiled by Xcode into default.metallib; SwiftPM builds have no terminal renderer.
                "Terminal/TerminalShaders.metal"
            ],
            resources: [
                .copy("Resources"),
                .copy("Extensions/ChromeAPIAugmentation.js"),
                .copy("Extensions/ChromeAPIBackgroundPrelude.js"),
                .copy("Extensions/ChromeAPIGapModules.json"),
                .copy("Extensions/ChromeContentCompat.js"),
                .copy("Extensions/ChromeStaticRules.js"),
                .copy("Extensions/ChromeWebStoreShim.js"),
                .copy("ContentBlocker/GenericCosmetics.js"),
                .copy("ContentBlocker/ProceduralCosmetics.js"),
                .copy("ContentBlocker/Scriptlets.js"),
                .copy("Reader/Readability.js"),
                .copy("Reader/ReaderView.js"),
                .copy("ContentBlocker/content-blocker-rules.json"),
                .copy("Extensions/public-suffix-list.dat"),
                .copy("ContentBlocker/BlockerResources"),
                .copy("Agent/AgentPage.js"),
                .copy("Agent/AgentInspector.js"),
                .copy("Agent/InspectorCDP.js")
            ],
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .binaryTarget(name: "GhosttyVt", path: "Vendor/GhosttyVt.xcframework"),
        .testTarget(
            name: "LiloTests",
            dependencies: ["Lilo", "GhosttyVt"],
            path: "LiloTests"
        )
    ]
)
