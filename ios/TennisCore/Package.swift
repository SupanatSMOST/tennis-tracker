// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TennisCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "TennisCore",
            targets: ["TennisCore"]
        )
    ],
    targets: [
        .target(
            name: "TennisCore",
            dependencies: []
        ),
        .testTarget(
            name: "TennisCoreTests",
            dependencies: ["TennisCore"]
        )
    ]
)
