// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ScribeSharedCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ScribeSharedCore", targets: ["ScribeSharedCore"]),
    ],
    targets: [
        .target(
            name: "ScribeSharedCore",
            path: "ScribeShared"
        ),
        .testTarget(
            name: "ScribeSharedCoreTests",
            dependencies: ["ScribeSharedCore"],
            path: "Tests/ScribeSharedCoreTests"
        ),
    ]
)
