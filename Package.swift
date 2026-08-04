// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OasisDistributionDependencies",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.4"
        ),
    ],
    targets: [
        .target(
            name: "SparkleDependency",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/SparkleDependency"
        ),
    ]
)
