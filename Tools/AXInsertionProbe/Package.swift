// swift-tools-version: 5.9

import PackageDescription

// The AX insertion probe for #69. It ships in no product and is not a target
// of the Spinnet package.
//
// This directory does not build on its own. script/ax_insertion_matrix.sh
// copies it into .build/ax-insertion-probe/ and adds, from Host A2 (commit
// af1a450) and checked byte for byte against that commit:
//
//   Sources/SpinnetCore/                      the whole SpinnetCore module
//   Sources/AXInsertionProbe/HostA2/*.swift   PluginHostServices.swift and the
//                                             two files it needs to compile
//
// so the probe calls the Host's own
// `AppKitPluginHostServiceProvider.insertText(_:intoApplication:)` unchanged.
//
// With --host current it instead adds this working tree's
// Sources/SpinnetCore/ and Sources/AXInsertionProbe/HostCurrent/
// (Sources/SpinnetHost/HostTextInserter.swift), and compiles the probe with
// HOST_CURRENT so it calls that inserter.
let package = Package(
    name: "AXInsertionProbe",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(name: "SpinnetCore"),
        .executableTarget(
            name: "AXInsertionProbe",
            dependencies: ["SpinnetCore"],
            // HOST_SWIFT_SETTINGS
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon")
            ]
        ),
        // The probe's own text fields, run as a separate App process so the
        // probe never inserts into itself.
        .executableTarget(
            name: "AXProbeFixture",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
