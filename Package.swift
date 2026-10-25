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
        .executable(name: "SpinnetHomebrewAskpass", targets: ["SpinnetHomebrewAskpass"]),
        .executable(name: "SpinnetToolAuthorizationClient", targets: ["SpinnetToolAuthorizationClient"]),
        .executable(name: "SpinnetPrivilegedToolHelper", targets: ["SpinnetPrivilegedToolHelper"]),
        .executable(name: "SpinnetBackgroundLifecycleProbe", targets: ["SpinnetBackgroundLifecycleProbe"]),
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
        .target(name: "SpinnetCore", resources: [.copy("Resources/HomebrewAutoremovePreview.rb"), .copy("Resources/HomebrewDryRun.rb"), .copy("Resources/HomebrewRead.rb"), .copy("Resources/HomebrewSourceGuard.rb"), .copy("Resources/HomebrewLinkPreview.rb"), .copy("Resources/HomebrewReadSources.json"), .copy("Resources/HomebrewPrivilegeMetadata.rb")]),
        .executableTarget(name: "SpinnetToolTaskRunner", dependencies: ["SpinnetCore"], linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "SpinnetHomebrewAskpass", dependencies: ["SpinnetCore"]),
        .executableTarget(name: "SpinnetToolAuthorizationClient", dependencies: ["SpinnetCore"]),
        .executableTarget(name: "SpinnetPrivilegedToolHelper", dependencies: ["SpinnetCore"]),
        .executableTarget(name: "SpinnetBackgroundLifecycleProbe", dependencies: ["SpinnetCore"], path: "Tools/BackgroundLifecycleProbe"),
        .executableTarget(name: "SpinnetReceiptInventory", dependencies: ["SpinnetCore"]),
        .executableTarget(name: "SpinnetPathInventory", dependencies: ["SpinnetCore"]),
        .executableTarget(name: "SpinnetVendorOrigin", dependencies: ["SpinnetCore", "SpinnetPathCancellation"]),
        .executableTarget(name: "SpinnetVendorOriginFixture", dependencies: ["SpinnetCore"], path: "Tests/Fixtures/Executables/SpinnetVendorOriginFixture"),
        .executableTarget(name: "SpinnetLaunchServiceInventory", dependencies: ["SpinnetCore", "SpinnetPathCancellation"]),
        .executableTarget(name: "SpinnetLaunchServiceFixture", dependencies: ["SpinnetCore"], path: "Tests/Fixtures/Executables/SpinnetLaunchServiceFixture"),
        .executableTarget(name: "SpinnetPathRemoval", dependencies: ["SpinnetCore", "SpinnetPathCancellation"]),
        .executableTarget(
            name: "SpinnetHost",
            dependencies: ["SpinnetCore"],
            linkerSettings: [
                .linkedFramework("AppKit", .when(platforms: [.macOS]))
            ]
        ),
        // The published contract (ADR 0013). Only the SDKs' sources are
        // built and embedded so the helper never
        // reads a file at run time.
        .target(
            name: "SpinnetPluginAPI",
            path: "PluginAPI",
            exclude: ["LICENSE", "README.md", "reference", "schemas", "spinnet.d.ts",
                      "spinnet-level-2.d.ts", "spinnet-level-3.d.ts", "spinnet-level-4.d.ts", "spinnet-level-5.d.ts", "spinnet-level-6.d.ts", "spinnet-level-7.d.ts", "adaptive-layout.d.ts", "external-app-connections.d.ts",
                      "homebrew-autoremove.d.ts", "spotify-controls.d.ts", "homebrew-management.d.ts", "catalogue.json", "catalogue-level-3.json", "fixtures", "candidates"],
            sources: ["SpinnetSDK.swift"],
            resources: [.embedInCode("spinnet.js"), .embedInCode("spinnet-command-output.js"), .embedInCode("spinnet-level-2.js"), .embedInCode("spinnet-level-3-adaptive.js"), .embedInCode("spinnet-level-3-autoremove.js")]
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
            dependencies: ["SpinnetCore"],
            path: "Tools/ViewSessionMeasurement"
        ),
        // Runs a Plugin's scripts in the real helper against recorded Host
        // Service answers. It must not depend on SpinnetHost, so a Plugin can
        // use it from its own repository (ADR 0014).
        .target(
            name: "SpinnetPluginTestKit",
            dependencies: ["SpinnetCore"],
            exclude: ["README.md"]
        ),
        // Build-time fixtures shared by Host tests, never a published product.
        .target(name: "SpinnetTestSupport", dependencies: ["SpinnetCore"], path: "Tests/Support"),
        .testTarget(
            name: "SpinnetPluginTestKitTests",
            dependencies: ["SpinnetPluginTestKit", "SpinnetCore", "SpinnetPluginHelper"]
        ),
        .testTarget(
            name: "SpinnetCoreTests",
            dependencies: ["SpinnetTestSupport", "SpinnetCore", "SpinnetPluginHelper", "SpinnetPluginTestKit", "SpinnetReceiptInventory", "SpinnetArchiveBootstrap", "SpinnetArchiveDecoder", "SpinnetPathInventory", "SpinnetPathRemoval", "SpinnetVendorOrigin", "SpinnetVendorOriginFixture", "SpinnetLaunchServiceInventory", "SpinnetLaunchServiceFixture"],
            resources: [.copy("ArchiveFixtures")]
        ),
        .testTarget(
            name: "SpinnetHostTests",
            dependencies: ["SpinnetHost", "SpinnetPluginTestKit", "SpinnetTestSupport"]
        )
    ]
)
