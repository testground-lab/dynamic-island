// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DynamicIsland",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "DynamicIsland", targets: ["DynamicIsland"]),
    ],
    targets: [
        .target(
            name: "IslandCore",
            resources: [.copy("Resources/Fixtures")]
        ),
        .executableTarget(
            name: "DynamicIsland",
            dependencies: ["IslandCore"]
        ),
        .testTarget(
            name: "IslandCoreTests",
            dependencies: ["IslandCore"]
        ),
    ]
)
