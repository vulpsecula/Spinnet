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
        .target(name: "SpinnetCore"),
        // Native Reviewed Tool execution is unavailable to the Plugin helper
        // and public recorded TestKit; only the Host and fixed workers link it.
        .target(name: "SpinnetReviewedTools", dependencies: ["SpinnetCore"]),
        .executableTarget(name: "SpinnetToolTaskRunner", dependencies: ["SpinnetReviewedTools", "SpinnetCore"], linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "SpinnetHomebrewAskpass", dependencies: ["SpinnetReviewedTools", "SpinnetCore"]),
        .executableTarget(name: "SpinnetToolAuthorizationClient", dependencies: ["SpinnetReviewedTools", "SpinnetCore"]),
        .executableTarget(name: "SpinnetPrivilegedToolHelper", dependencies: ["SpinnetReviewedTools", "SpinnetCore"]),
        .executableTarget(name: "SpinnetBackgroundLifecycleProbe", dependencies: ["SpinnetReviewedTools", "SpinnetCore"], path: "Tools/BackgroundLifecycleProbe"),
        .executableTarget(name: "SpinnetReceiptInventory", dependencies: ["SpinnetReviewedTools", "SpinnetCore"]),
        .executableTarget(name: "SpinnetPathInventory", dependencies: ["SpinnetReviewedTools", "SpinnetCore"]),
        .executableTarget(name: "SpinnetVendorOrigin", dependencies: ["SpinnetReviewedTools", "SpinnetCore", "SpinnetPathCancellation"]),
        .executableTarget(name: "SpinnetVendorOriginFixture", dependencies: ["SpinnetReviewedTools", "SpinnetCore"], path: "Tests/Fixtures/Executables/SpinnetVendorOriginFixture"),
        .executableTarget(name: "SpinnetLaunchServiceInventory", dependencies: ["SpinnetReviewedTools", "SpinnetCore", "SpinnetPathCancellation"]),
        .executableTarget(name: "SpinnetLaunchServiceFixture", dependencies: ["SpinnetReviewedTools", "SpinnetCore"], path: "Tests/Fixtures/Executables/SpinnetLaunchServiceFixture"),
        .executableTarget(name: "SpinnetPathRemoval", dependencies: ["SpinnetReviewedTools", "SpinnetCore", "SpinnetPathCancellation"]),
        .executableTarget(
            name: "SpinnetHost",
            dependencies: ["SpinnetCore", "SpinnetReviewedTools"],
            linkerSettings: [
                .linkedFramework("AppKit", .when(platforms: [.macOS]))
            ]
        ),
        // The published contract (ADR 0013). Only the SDKs' sources are
        // built and embedded so the helper never
        // reads a file at run time.
        .target(
            name: "SpinnetPluginAPI",
            path: "PluginAPI/sdk",
            exclude: ["adaptive-layout.d.ts", "external-app-connections.d.ts", "homebrew-autoremove.d.ts",
                      "homebrew-management.d.ts", "spinnet.d.ts", "views.d.ts", "spotify-controls.d.ts",
                      "update-source.d.ts"],
            sources: ["SpinnetSDK.swift"],
            resources: [.embedInCode("view-builders.js"), .embedInCode("spinnet.js"),
                        .embedInCode("adaptive-layout.js"), .embedInCode("autoremove.js"),
                        .embedInCode("command-output.js")]
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
            dependencies: ["SpinnetReviewedTools", "SpinnetTestSupport", "SpinnetCore", "SpinnetPluginHelper", "SpinnetPluginTestKit", "SpinnetPrivilegedToolHelper", "SpinnetReceiptInventory", "SpinnetArchiveBootstrap", "SpinnetArchiveDecoder", "SpinnetPathInventory", "SpinnetPathRemoval", "SpinnetVendorOrigin", "SpinnetVendorOriginFixture", "SpinnetLaunchServiceInventory", "SpinnetLaunchServiceFixture"],
            resources: [.copy("ArchiveFixtures")]
        ),
        .testTarget(
            name: "SpinnetHostTests",
            dependencies: ["SpinnetReviewedTools", "SpinnetHost", "SpinnetPluginTestKit", "SpinnetTestSupport"]
        )
    ]
)
