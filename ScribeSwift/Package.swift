// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Scribe",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "Scribe",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Scribe",
            resources: [
                .process("Info.plist")
            ]
        )
    ]
)
