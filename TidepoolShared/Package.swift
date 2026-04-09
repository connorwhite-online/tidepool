// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TidepoolShared",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "TidepoolShared",
            targets: ["TidepoolShared"]
        )
    ],
    targets: [
        .target(
            name: "TidepoolShared",
            path: "Sources/TidepoolShared"
        ),
        .testTarget(
            name: "TidepoolSharedTests",
            dependencies: ["TidepoolShared"],
            path: "Tests/TidepoolSharedTests"
        )
    ]
)
