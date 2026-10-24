// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AgentIsland",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentIsland", targets: ["AgentIsland"]),
        .executable(name: "island", targets: ["island"]),
    ],
    targets: [
        .target(name: "IslandCore"),
        .executableTarget(name: "AgentIsland", dependencies: ["IslandCore"]),
        .executableTarget(name: "island", dependencies: ["IslandCore"]),
    ]
)
