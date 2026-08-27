import Foundation
import Testing

@Suite
struct `Architecture boundaries` {
    private let fileManager = FileManager.default

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SecondBrainMCP", isDirectory: true)
    }

    @Test
    func `Source root contains only Frontend, Backend, and Shared`() throws {
        let entries = try fileManager.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        let directories = try entries
            .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
            .map(\.lastPathComponent)

        #expect(Set(directories) == ["Frontend", "Backend", "Shared"])
    }

    @Test
    func `Only Frontend may import MCP`() throws {
        let forbiddenImports = try forbiddenImportOccurrences(
            layers: ["Backend", "Shared"],
            imports: ["import MCP"]
        )

        #expect(forbiddenImports.isEmpty, "Forbidden imports: \(forbiddenImports)")
    }

    @Test
    func `Backend does not depend on Frontend MCP adapter types`() throws {
        let forbidden = [
            "ToolController",
            "ToolDefinition",
            "ToolRequestDecoder",
            "ToolResultMapper",
            "MCPServerSetup",
        ]
        var occurrences: [String] = []
        let backend = sourceRoot.appendingPathComponent("Backend", isDirectory: true)

        for fileURL in try swiftFiles(under: backend) {
            let lines = try String(contentsOf: fileURL, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                for token in forbidden where line.contains(token) {
                    let relativePath = fileURL.path.replacingOccurrences(
                        of: sourceRoot.path + "/",
                        with: ""
                    )
                    occurrences.append("\(relativePath):\(index + 1): \(token)")
                }
            }
        }

        #expect(
            occurrences.isEmpty,
            "Frontend MCP adapters leaked into Backend: \(occurrences)"
        )
    }

    @Test
    func `Shared remains free of feature frameworks`() throws {
        let forbiddenImports = try forbiddenImportOccurrences(
            layers: ["Shared"],
            imports: [
                "import MCP",
                "import AVFoundation",
                "import CoreGraphics",
                "import ImageIO",
                "import PDFKit",
            ]
        )

        #expect(forbiddenImports.isEmpty, "Forbidden imports: \(forbiddenImports)")
    }

    @Test
    func `Shared file-domain enums remain separated`() throws {
        let expectedDeclarations = [
            "FileFormat.swift": "enum FileFormat",
            "VaultArea.swift": "enum VaultArea",
            "FileCRUDOperation.swift": "enum FileCRUDOperation",
            "FileUpdateMode.swift": "enum FileUpdateMode",
            "FileCreateTransform.swift": "enum FileCreateTransform",
            "FileRoutingError.swift": "enum FileRoutingError",
        ]
        let directory = sourceRoot.appendingPathComponent(
            "Shared/Files",
            isDirectory: true
        )

        for (filename, expectedDeclaration) in expectedDeclarations {
            let fileURL = directory.appendingPathComponent(filename)
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let enumDeclarations = source
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("enum ") }

            #expect(enumDeclarations.count == 1)
            #expect(enumDeclarations.first?.hasPrefix(expectedDeclaration + ":") == true)
        }
    }

    @Test
    func `Shared file requests remain grouped by CRUD operation`() throws {
        let expectedDeclarations = [
            "CreateFileRequest.swift": ["struct CreateFileRequest"],
            "ReadFileRequest.swift": [
                "struct CanvasReadSelection",
                "struct ReadFileOptions",
                "struct ReadFileRequest",
                "struct PDFOutlineMetadataEntry",
                "struct FileReadMetadata",
            ],
            "UpdateFileRequest.swift": ["struct TextReplacement", "struct UpdateFileRequest"],
            "DeleteFileRequest.swift": ["struct DeleteFileRequest"],
        ]
        let directory = sourceRoot.appendingPathComponent(
            "Shared/Files",
            isDirectory: true
        )

        for (filename, expected) in expectedDeclarations {
            let fileURL = directory.appendingPathComponent(filename)
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let declarations = source
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("struct ") }

            #expect(declarations.count == expected.count)
            for declaration in expected {
                #expect(source.contains(declaration + ":"))
            }
        }
        #expect(!fileManager.fileExists(
            atPath: directory.appendingPathComponent("FileRequests.swift").path
        ))
    }

    @Test
    func `Format operations remain persistence-free`() throws {
        let directory = sourceRoot.appendingPathComponent(
            "Backend/Files/Operations",
            isDirectory: true
        )
        var occurrences: [String] = []

        for fileURL in try swiftFiles(under: directory) {
            let lines = try String(contentsOf: fileURL, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() where line.contains("VaultCRUDStore") {
                let relativePath = fileURL.path.replacingOccurrences(
                    of: sourceRoot.path + "/",
                    with: ""
                )
                occurrences.append("\(relativePath):\(index + 1)")
            }
        }

        #expect(occurrences.isEmpty, "Persistence leaked into format operations: \(occurrences)")
    }

    @Test
    func `File resource policy remains backend-owned`() throws {
        let sharedFormatURL = sourceRoot.appendingPathComponent(
            "Shared/Files/FileFormat.swift"
        )
        let sharedFormat = try String(contentsOf: sharedFormatURL, encoding: .utf8)
        #expect(!sharedFormat.contains("maximumFileBytes"))

        let policyURL = sourceRoot.appendingPathComponent(
            "Backend/Files/Validation/FileResourcePolicy.swift"
        )
        #expect(fileManager.fileExists(atPath: policyURL.path))

        let operationsURL = sourceRoot.appendingPathComponent(
            "Backend/Files/Operations",
            isDirectory: true
        )
        let forbidden = [
            "private let maxBytes",
            "10 * 1024 * 1024",
            "25 * 1024 * 1024",
            "512 * 1024 * 1024",
        ]
        var occurrences: [String] = []
        for fileURL in try swiftFiles(under: operationsURL) {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for token in forbidden where source.contains(token) {
                occurrences.append("\(fileURL.lastPathComponent): \(token)")
            }
        }

        #expect(occurrences.isEmpty, "Format handlers duplicated storage limits: \(occurrences)")
    }

    @Test
    func `Search execution policy remains backend-owned`() throws {
        let frontend = sourceRoot.appendingPathComponent(
            "Frontend",
            isDirectory: true
        )
        let forbidden = [
            "SearchCorpusBuilder",
            "VaultSearchEngine",
            "PDFSearchAtomProvider",
            "LiteralSearchMatchingStrategy",
            "VaultFileListingService",
            "VaultLinkCorpusBuilder",
            "VaultLinkQueryEngine",
            "ObsidianWikiLinkParser",
        ]
        var occurrences: [String] = []
        for fileURL in try swiftFiles(under: frontend) {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for token in forbidden where source.contains(token) {
                occurrences.append("\(fileURL.lastPathComponent): \(token)")
            }
        }

        #expect(occurrences.isEmpty, "Backend search policy leaked into Frontend: \(occurrences)")
    }

    @Test
    func `Backend composition has one root`() throws {
        var occurrences: [String] = []

        for fileURL in try swiftFiles(under: sourceRoot) {
            let lines = try String(contentsOf: fileURL, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated()
            where line.contains("FileFormatCatalogFactory.build(") {
                let relativePath = fileURL.path.replacingOccurrences(
                    of: sourceRoot.path + "/",
                    with: ""
                )
                occurrences.append("\(relativePath):\(index + 1)")
            }
        }

        #expect(occurrences.count == 1)
        #expect(occurrences.first?.hasPrefix("Backend/Infrastructure/VaultRuntime.swift:") == true)
    }

    @Test
    func `Application entry point owns backend startup`() throws {
        var occurrences: [String] = []

        for fileURL in try swiftFiles(under: sourceRoot) {
            let lines = try String(contentsOf: fileURL, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated()
            where line.contains("VaultRuntime.bootstrap(") {
                let relativePath = fileURL.path.replacingOccurrences(
                    of: sourceRoot.path + "/",
                    with: ""
                )
                occurrences.append("\(relativePath):\(index + 1)")
            }
        }

        #expect(occurrences.count == 1)
        #expect(occurrences.first?.hasPrefix("Frontend/Application/main.swift:") == true)

        let setupURL = sourceRoot.appendingPathComponent(
            "Frontend/MCP/MCPServerSetup.swift"
        )
        let setupSource = try String(contentsOf: setupURL, encoding: .utf8)
        #expect(!setupSource.contains("VaultRuntime"))
    }

    @Test
    func `Server configuration remains frontend-owned`() throws {
        var occurrences: [String] = []

        for layer in ["Backend", "Shared"] {
            let directory = sourceRoot.appendingPathComponent(layer, isDirectory: true)
            for fileURL in try swiftFiles(under: directory) {
                let lines = try String(contentsOf: fileURL, encoding: .utf8)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                for (index, line) in lines.enumerated() where line.contains("ServerConfig") {
                    let relativePath = fileURL.path.replacingOccurrences(
                        of: sourceRoot.path + "/",
                        with: ""
                    )
                    occurrences.append("\(relativePath):\(index + 1)")
                }
            }
        }

        #expect(occurrences.isEmpty, "Frontend configuration leaked across boundaries: \(occurrences)")
        #expect(fileManager.fileExists(atPath: sourceRoot
            .appendingPathComponent("Frontend/Configuration/ServerConfig.swift")
            .path))
    }

    @Test
    func `File routing delegates transaction mechanics`() throws {
        let directory = sourceRoot.appendingPathComponent(
            "Backend/Files/Routing",
            isDirectory: true
        )
        let forbidden = [
            "GitRepository",
            "AsyncExclusiveGate",
            "commitChange(",
            "commitDeletion(",
            "gitCommitFailed",
        ]
        var occurrences: [String] = []

        for fileURL in try swiftFiles(under: directory) {
            let lines = try String(contentsOf: fileURL, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                for token in forbidden where line.contains(token) {
                    let relativePath = fileURL.path.replacingOccurrences(
                        of: sourceRoot.path + "/",
                        with: ""
                    )
                    occurrences.append("\(relativePath):\(index + 1): \(token)")
                }
            }
        }

        #expect(occurrences.isEmpty, "Transaction mechanics leaked into routing: \(occurrences)")
    }

    @Test
    func `File service delegates binding resolution to the catalog`() throws {
        let fileURL = sourceRoot.appendingPathComponent(
            "Backend/Files/Routing/VaultFileService.swift"
        )
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        let forbidden = [
            "definition(for:",
            "allowedAreas",
            "operationNotSupported",
        ]
        let occurrences = forbidden.filter { source.contains($0) }

        #expect(occurrences.isEmpty, "Binding resolution leaked into the file service: \(occurrences)")
    }

    @Test
    func `Backend routing catalog does not leak across layer boundaries`() throws {
        let forbidden = [
            "FileFormatCatalog",
            "FileFormatDefinition",
            "FormatOperations",
            "FileOperationBinding<",
            "FileOperationFamily",
        ]
        var occurrences: [String] = []

        for layer in ["Frontend", "Shared"] {
            let directory = sourceRoot.appendingPathComponent(layer, isDirectory: true)
            for fileURL in try swiftFiles(under: directory) {
                let lines = try String(contentsOf: fileURL, encoding: .utf8)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                for (index, line) in lines.enumerated() {
                    for token in forbidden where line.contains(token) {
                        let relativePath = fileURL.path.replacingOccurrences(
                            of: sourceRoot.path + "/",
                            with: ""
                        )
                        occurrences.append("\(relativePath):\(index + 1): \(token)")
                    }
                }
            }
        }

        #expect(occurrences.isEmpty, "Backend routing types leaked across boundaries: \(occurrences)")
    }

    @Test
    func `Concrete backend file service does not leak across layer boundaries`() throws {
        var occurrences: [String] = []

        for layer in ["Frontend", "Shared"] {
            let directory = sourceRoot.appendingPathComponent(layer, isDirectory: true)
            for fileURL in try swiftFiles(under: directory) {
                let lines = try String(contentsOf: fileURL, encoding: .utf8)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                for (index, line) in lines.enumerated() where line.contains("VaultFileService") {
                    let relativePath = fileURL.path.replacingOccurrences(
                        of: sourceRoot.path + "/",
                        with: ""
                    )
                    occurrences.append("\(relativePath):\(index + 1)")
                }
            }
        }

        #expect(occurrences.isEmpty, "Concrete file service leaked across boundaries: \(occurrences)")
    }

    @Test
    func `File tool controller delegates transport mechanics`() throws {
        let fileURL = sourceRoot.appendingPathComponent(
            "Frontend/MCP/Files/FileToolController.swift"
        )
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        let forbidden = [
            "stringValue",
            "arrayValue",
            "objectValue",
            "withThrowingTaskGroup",
            "Tool.Content",
            "base64EncodedString",
        ]
        let occurrences = forbidden.filter { source.contains($0) }

        #expect(occurrences.isEmpty, "Transport mechanics leaked into controller: \(occurrences)")
    }

    private func forbiddenImportOccurrences(
        layers: [String],
        imports: Set<String>
    ) throws -> [String] {
        var occurrences: [String] = []

        for layer in layers {
            let layerURL = sourceRoot.appendingPathComponent(layer, isDirectory: true)
            for fileURL in try swiftFiles(under: layerURL) {
                let lines = try String(contentsOf: fileURL, encoding: .utf8)
                    .split(separator: "\n", omittingEmptySubsequences: false)

                for (index, line) in lines.enumerated() {
                    let normalized = line.trimmingCharacters(in: .whitespaces)
                    if imports.contains(normalized) {
                        let relativePath = fileURL.path.replacingOccurrences(
                            of: sourceRoot.path + "/",
                            with: ""
                        )
                        occurrences.append("\(relativePath):\(index + 1): \(normalized)")
                    }
                }
            }
        }

        return occurrences.sorted()
    }

    private func swiftFiles(under directory: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator.compactMap { entry in
            guard let fileURL = entry as? URL, fileURL.pathExtension == "swift" else {
                return nil
            }
            return fileURL
        }
    }
}
