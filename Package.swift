// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SecondBrainMCP",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        // Audited 0.12.1-based JSON-string fidelity fix; provenance in SECURITY.md.
        .package(
            url: "https://github.com/bitbemol/swift-mcp-sdk.git",
            revision: "af48e3f7070965579ece835173c279cb04c23543"
        ),
        // Audited 1.0.0-based stopped-child exit detection fix; provenance in SECURITY.md.
        .package(
            url: "https://github.com/bitbemol/swift-subprocess.git",
            revision: "81082b28a502f5be268186fd5c2525166eb5ad6c"
        )
    ],
    targets: [
        .executableTarget(
            name: "second-brain-mcp",
            dependencies: [
                .product(name: "MCP", package: "swift-mcp-sdk"),
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
