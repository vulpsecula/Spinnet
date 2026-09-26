// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Spinnet",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SpinnetCore", targets: ["SpinnetCore"]),
        .library(name: "SpinnetPluginTestKit", targets: ["SpinnetPluginTestKit"]),
        .executable(name: "SpinnetHost", targets: ["SpinnetHost"]),
        .executable(name: "SpinnetPluginHelper", targets: ["SpinnetPluginHelper"])
    ],
    targets: [
        .target(name: "SpinnetCore"),
        .executableTarget(
            name: "SpinnetHost",
            dependencies: ["SpinnetCore"],
            linkerSettings: [
                .linkedFramework("AppKit", .when(platforms: [.macOS]))
            ]
        ),
        // The published contract (ADR 0013). Only the SDK's source is built,
        // embedded in the helper so it never reads a file at run time.
        .target(
            name: "SpinnetPluginAPI",
            path: "PluginAPI",
            exclude: ["LICENSE", "README.md", "schemas", "spinnet.d.ts"],
            sources: ["SpinnetSDK.swift"],
            resources: [.embedInCode("spinnet.js")]
        ),
        .executableTarget(
            name: "SpinnetPluginHelper",
            dependencies: ["SpinnetCore", "SpinnetPluginAPI"],
            linkerSettings: [
                .linkedFramework("JavaScriptCore", .when(platforms: [.macOS]))
            ]
        ),
        // Runs a Plugin's scripts in the real helper against recorded Host
        // Service answers. It must not depend on SpinnetHost, so a Plugin can
        // use it from its own repository (ADR 0014).
        .target(
            name: "SpinnetPluginTestKit",
            dependencies: ["SpinnetCore"],
            exclude: ["README.md"]
        ),
        .testTarget(
            name: "SpinnetPluginTestKitTests",
            dependencies: ["SpinnetPluginTestKit", "SpinnetCore", "SpinnetPluginHelper"]
        ),
        .testTarget(
            name: "SpinnetCoreTests",
            dependencies: ["SpinnetCore", "SpinnetPluginHelper", "SpinnetPluginTestKit"]
        ),
        // The Bundled Plugins' behaviour, run through the Plugin test kit.
        .testTarget(
            name: "BundledPluginTests",
            dependencies: ["SpinnetPluginTestKit", "SpinnetCore", "SpinnetPluginHelper"]
        ),
        .testTarget(
            name: "SpinnetHostTests",
            dependencies: ["SpinnetHost"]
        )
    ]
)
