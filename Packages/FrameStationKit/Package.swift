// swift-tools-version:5.9
import PackageDescription

// Everything the four apps share: API client, sync engine, blob cache.
// UI stays in the platform targets; this package must never import SwiftUI.
let package = Package(
    name: "FrameStationKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
    ],
    products: [
        .library(name: "FrameStationKit", targets: ["FrameStationKit"]),
    ],
    dependencies: [
        .package(path: "../FrameStationAPI"),
    ],
    targets: [
        .target(
            name: "FrameStationKit",
            dependencies: [
                .product(name: "FrameStationAPI", package: "FrameStationAPI"),
            ]
        ),
        .testTarget(
            name: "FrameStationKitTests",
            dependencies: ["FrameStationKit"]
        ),
    ]
)
