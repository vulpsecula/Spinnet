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
        .executable(name: "SpinnetHost", targets: ["SpinnetHost"]),
        .executable(name: "SpinnetPluginHelper", targets: ["SpinnetPluginHelper"])
    ],
    targets: [
        .target(name: "SpinnetCore"),
        .executableTarget(
            name: "SpinnetHost",
            dependencies: ["SpinnetCore"],
            resources: [
                .copy("Resources/ClipboardHistory.spinnetplugin")
            ],
            linkerSettings: [
                .linkedFramework("AppKit", .when(platforms: [.macOS]))
            ]
        ),
        .executableTarget(
            name: "SpinnetPluginHelper",
            dependencies: ["SpinnetCore"],
            linkerSettings: [
                .linkedFramework("JavaScriptCore", .when(platforms: [.macOS]))
            ]
        ),
        .testTarget(
            name: "SpinnetCoreTests",
            dependencies: ["SpinnetCore", "SpinnetPluginHelper"]
        ),
        .testTarget(
            name: "SpinnetHostTests",
            dependencies: ["SpinnetHost"]
        )
    ]
)
