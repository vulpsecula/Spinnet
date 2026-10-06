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
        // The published contract (ADR 0013). Only the SDKs' sources are
        // built: Level 1's, Level 2's and each retired candidate revision's,
        // embedded in the helper so it never reads a file at run time.
        .target(
            name: "SpinnetPluginAPI",
            path: "PluginAPI",
            exclude: ["LICENSE", "README.md", "proposals", "reference", "schemas", "spinnet.d.ts",
                      "spinnet-level-2.d.ts", "catalogue.json", "fixtures",
                      "candidates/README.md", "candidates/schemas",
                      "candidates/namespaces/r1/reference.md", "candidates/namespaces/r1/candidate.json",
                      "candidates/namespaces/r1/catalogue.json", "candidates/namespaces/r1/catalogue.schema.json",
                      "candidates/namespaces/r1/level1-mapping.md", "candidates/namespaces/r1/namespaces.d.ts",
                      "candidates/namespaces/r1/namespaces.schema.json",
                      "candidates/host_operations/r1/reference.md", "candidates/host_operations/r1/candidate.json",
                      "candidates/host_operations/r1/host-operations.schema.json",
                      "candidates/host_operations/r1/host-operations.d.ts", "candidates/host_operations/r1/fixtures",
                      "candidates/collections/r1/reference.md", "candidates/collections/r1/candidate.json",
                      "candidates/collections/r1/collections.schema.json", "candidates/collections/r1/collections.d.ts",
                      "candidates/collections/r1/fixtures",
                      "candidates/collections/r2/reference.md", "candidates/collections/r2/candidate.json",
                      "candidates/collections/r2/collections.schema.json", "candidates/collections/r2/collections.d.ts",
                      "candidates/collections/r2/fixtures",
                      "candidates/host_operations/r2/reference.md", "candidates/host_operations/r2/candidate.json",
                      "candidates/host_operations/r2/host-operations.schema.json",
                      "candidates/host_operations/r2/host-operations.d.ts", "candidates/host_operations/r2/fixtures",
                      "candidates/collections/r3/reference.md", "candidates/collections/r3/candidate.json",
                      "candidates/collections/r3/collections.schema.json", "candidates/collections/r3/collections.d.ts",
                      "candidates/collections/r3/fixtures"],
            sources: ["SpinnetSDK.swift"],
            resources: [.embedInCode("spinnet.js"), .embedInCode("spinnet-level-2.js"),
                        .embedInCode("candidates/namespaces/r1/namespaces.js"),
                        .embedInCode("candidates/host_operations/r1/host_operations.js"),
                        .embedInCode("candidates/collections/r1/collections.js"),
                        .embedInCode("candidates/collections/r3/collections-r3.js")]
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
