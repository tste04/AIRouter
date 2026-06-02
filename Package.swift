// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AIRouter",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "AIRouter",
            targets: ["AIRouter"]
        )
    ],
    targets: [
        .target(
            name: "AIRouter"
        ),
        .testTarget(
            name: "AIRouterTests",
            dependencies: ["AIRouter"]
        )
    ]
)
