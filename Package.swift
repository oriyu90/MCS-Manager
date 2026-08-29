// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MCServerManager",
    defaultLocalization: "ja",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MCServerManager", targets: ["MCServerManager"])
    ],
    targets: [
        .executableTarget(
            name: "MCServerManager",
            path: "Sources/MCServerManager",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "MCServerManagerTests",
            dependencies: ["MCServerManager"],
            path: "Tests/MCServerManagerTests"
        )
    ]
)
