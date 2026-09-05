// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SecondBrainMCP",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        // Temporary audited SDK patch: prevent data-URI-looking JSON strings from being rewritten.
        // No security checks are bypassed or new network behavior introduced.
        // Pinned revision, patch scope and license: Vendor/swift-sdk/README.md.
        // Remove this local copy and restore the official SDK dependency once an audited upstream
        // release fixes the bug and passes SDKJSONStringFidelityTests and the full test suite.
        .package(path: "Vendor/swift-sdk"),
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
