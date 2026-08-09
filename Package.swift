// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SecondBrainMCP",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "second-brain-mcp", targets: ["SecondBrainMCP"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "SecondBrainMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Subprocess", package: "swift-subprocess")
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "SecondBrainMCPTests",
            dependencies: ["SecondBrainMCP"]
        )
    ]
)
// Note: PDFKit is a system framework — no dependency entry needed.
// Just `import PDFKit` in the source files that use it.
