// swift-tools-version:5.9
import PackageDescription

// The wire contract, shared by the Vapor server and every Apple client.
//
// Deliberately zero dependencies and every Apple platform: if this package ever
// gains a server-only dependency, the iOS and tvOS targets stop building. That
// constraint is the whole point — it is what keeps one set of types honest
// across both sides of the API.
let package = Package(
    name: "FrameStationAPI",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
    ],
    products: [
        .library(name: "FrameStationAPI", targets: ["FrameStationAPI"]),
    ],
    targets: [
        .target(name: "FrameStationAPI"),
    ]
)
