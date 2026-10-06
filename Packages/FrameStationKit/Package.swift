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
        .library(name: "FrameStationKit", targets: ["FrameStationKit", "FrameStationAnalysis"]),
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
        // Looking at photographs, with Vision on the device. Deliberately
        // depends on nothing, least of all the client above, so nothing in it
        // can send a picture anywhere. `AnalysisBoundaryTests` keeps it so.
        .target(name: "FrameStationAnalysis"),
        .testTarget(
            name: "FrameStationKitTests",
            dependencies: ["FrameStationKit", "FrameStationAnalysis"]
        ),
    ]
)
