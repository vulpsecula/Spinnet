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
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices")
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
