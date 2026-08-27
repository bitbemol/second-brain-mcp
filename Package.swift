// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SecondBrainMCP",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "second-brain-mcp",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Subprocess", package: "swift-subprocess")
            ],
            path: "Sources/SecondBrainMCP"
        ),
        .testTarget(
            name: "SecondBrainMCPTests",
            dependencies: ["second-brain-mcp"]
        )
    ]
)
