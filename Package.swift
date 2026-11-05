// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacDevinUsage",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MacDevinUsage", targets: ["MacDevinUsage"])
    ],
    targets: [
        .executableTarget(
            name: "MacDevinUsage",
            path: "Sources/MacDevinUsage",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MacDevinUsageTests",
            dependencies: ["MacDevinUsage"],
            path: "Tests/MacDevinUsageTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
