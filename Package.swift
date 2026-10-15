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
        .executable(name: "SpinnetPluginHelper", targets: ["SpinnetPluginHelper"]),
        .executable(name: "SpinnetToolTaskRunner", targets: ["SpinnetToolTaskRunner"]),
        .executable(name: "SpinnetToolAuthorizationClient", targets: ["SpinnetToolAuthorizationClient"]),
        .executable(name: "SpinnetPrivilegedToolHelper", targets: ["SpinnetPrivilegedToolHelper"]),
        .executable(name: "SpinnetReceiptInventory", targets: ["SpinnetReceiptInventory"]),
        .executable(name: "SpinnetArchiveBootstrap", targets: ["SpinnetArchiveBootstrap"]),
        .executable(name: "SpinnetArchiveDecoder", targets: ["SpinnetArchiveDecoder"]),
        .executable(name: "SpinnetPathInventory", targets: ["SpinnetPathInventory"]),
        .executable(name: "SpinnetVendorOrigin", targets: ["SpinnetVendorOrigin"]),
        .executable(name: "SpinnetPathRemoval", targets: ["SpinnetPathRemoval"]),
        .executable(name: "SpinnetLaunchServiceInventory", targets: ["SpinnetLaunchServiceInventory"])
    ],
    targets: [
        .target(name: "SpinnetPathCancellation", publicHeadersPath: "include"),
        .executableTarget(name: "SpinnetArchiveBootstrap"),
        .executableTarget(name: "SpinnetArchiveDecoder", linkerSettings: [.linkedLibrary("archive"), .linkedLibrary("compression"), .linkedLibrary("xar"), .linkedLibrary("z")]),
        .target(name: "SpinnetCore", resources: [.copy("Resources/HomebrewDryRun.rb"), .copy("Resources/HomebrewRead.rb"), .copy("Resources/HomebrewSourceGuard.rb"), .copy("Resources/HomebrewLinkPreview.rb"), .copy("Resources/HomebrewReadSources.json"), .copy("Resources/HomebrewPrivilegeMetadata.rb")]),
        .executableTarget(name: "SpinnetToolTaskRunner", dependencies: ["SpinnetCore"], resources: [.copy("Resources/HomebrewPrivilegeBridge.rb")], linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "SpinnetToolAuthorizationClient", dependencies: ["SpinnetCore"]),
        .executableTarget(name: "SpinnetPrivilegedToolHelper", dependencies: ["SpinnetCore"]),
        .executableTarget(name: "SpinnetReceiptInventory", dependencies: ["SpinnetCore"]),
        .executableTarget(name: "SpinnetPathInventory", dependencies: ["SpinnetCore"]),
        .executableTarget(name: "SpinnetVendorOrigin", dependencies: ["SpinnetCore", "SpinnetPathCancellation"]),
        .executableTarget(name: "SpinnetVendorOriginFixture", dependencies: ["SpinnetCore"]),
        .executableTarget(name: "SpinnetLaunchServiceInventory", dependencies: ["SpinnetCore", "SpinnetPathCancellation"]),
        .executableTarget(name: "SpinnetLaunchServiceFixture", dependencies: ["SpinnetCore"]),
        .executableTarget(name: "SpinnetPathRemoval", dependencies: ["SpinnetCore", "SpinnetPathCancellation"]),
        .executableTarget(
            name: "SpinnetHost",
            dependencies: ["SpinnetCore"],
            linkerSettings: [
                .linkedFramework("AppKit", .when(platforms: [.macOS]))
            ]
        ),
        // The published contract (ADR 0013). Only the SDKs' sources are
        // built, stable and exact opt-in candidates, embedded so the helper never
        // reads a file at run time.
        .target(
            name: "SpinnetPluginAPI",
            path: "PluginAPI",
            exclude: ["LICENSE", "README.md", "proposals", "reference", "schemas", "spinnet.d.ts",
                      "spinnet-level-2.d.ts", "homebrew-management.d.ts", "catalogue.json", "fixtures", "candidates/README.md", "candidates/collections", "candidates/host_operations",
                      "candidates/namespaces", "candidates/schemas", "candidates/adaptive_layout/r1/candidate.json",
                      "candidates/adaptive_layout/r1/README.md", "candidates/adaptive_layout/r1/adaptive-layout.d.ts",
                      "candidates/adaptive_layout/r1/adaptive-layout.schema.json", "candidates/adaptive_layout/r1/fixtures", "candidates/adaptive_layout/r2/candidate.json",
                      "candidates/adaptive_layout/r2/README.md", "candidates/adaptive_layout/r2/adaptive-layout.d.ts",
                      "candidates/adaptive_layout/r2/adaptive-layout.schema.json", "candidates/adaptive_layout/r2/fixtures"],
            sources: ["SpinnetSDK.swift"],
            resources: [.embedInCode("spinnet.js"), .embedInCode("spinnet-level-2.js"), .embedInCode("candidates/adaptive_layout/r1/adaptive-layout.js"), .embedInCode("candidates/adaptive_layout/r2/adaptive-layout-r2.js")]
        ),
        .executableTarget(
            name: "SpinnetPluginHelper",
            dependencies: ["SpinnetCore", "SpinnetPluginAPI"],
            linkerSettings: [
                .linkedFramework("JavaScriptCore", .when(platforms: [.macOS]))
            ]
        ),
        // Measures View Session latency and memory over the real helper (W13
        // #60). It ships in no product; script/measure_view_sessions.sh
        // builds and runs it in release.
        .executableTarget(
            name: "SpinnetViewSessionMeasurement",
            dependencies: ["SpinnetCore"]
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
            dependencies: ["SpinnetCore", "SpinnetPluginHelper", "SpinnetPluginTestKit", "SpinnetReceiptInventory", "SpinnetArchiveBootstrap", "SpinnetArchiveDecoder", "SpinnetPathInventory", "SpinnetPathRemoval", "SpinnetVendorOrigin", "SpinnetVendorOriginFixture", "SpinnetLaunchServiceInventory", "SpinnetLaunchServiceFixture"],
            resources: [.copy("ArchiveFixtures")]
        ),
        // The Bundled Plugins' behaviour, run through the Plugin test kit.
        .testTarget(
            name: "BundledPluginTests",
            dependencies: ["SpinnetPluginTestKit", "SpinnetCore", "SpinnetPluginHelper"]
        ),
        .testTarget(
            name: "SpinnetHostTests",
            dependencies: ["SpinnetHost", "SpinnetPluginTestKit"]
        )
    ]
)
