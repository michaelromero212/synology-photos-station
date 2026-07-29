// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FrameStationServer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FrameStationServer", targets: ["FrameStationServer"]),
    ],
    dependencies: [
        // Shared with the Apple clients. Lives outside this package so the apps
        // never drag Vapor, PostgresKit, and SwiftNIO into an iOS build.
        .package(path: "../Packages/FrameStationAPI"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.92.0"),
        .package(url: "https://github.com/vapor/postgres-kit.git", from: "2.12.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "FrameStationServer",
            dependencies: [
                .product(name: "FrameStationAPI", package: "FrameStationAPI"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "PostgresKit", package: "postgres-kit"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            resources: [.copy("Migrations/SQL")]
        ),
    ]
)
