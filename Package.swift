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
        .executable(name: "SpinnetHost", targets: ["SpinnetHost"])
    ],
    targets: [
        .target(name: "SpinnetCore"),
        .executableTarget(
            name: "SpinnetHost",
            dependencies: ["SpinnetCore"],
            resources: [
                .copy("Resources/SpinnetFixture.spinnetplugin")
            ],
            linkerSettings: [
                .linkedFramework("AppKit", .when(platforms: [.macOS]))
            ]
        ),
        .testTarget(
            name: "SpinnetCoreTests",
            dependencies: ["SpinnetCore"]
        ),
        .testTarget(
            name: "SpinnetHostTests",
            dependencies: ["SpinnetHost"]
        )
    ]
)
