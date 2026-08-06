import Foundation
import Testing

@Suite("Architecture boundaries")
struct ArchitectureBoundaryTests {
    private let fileManager = FileManager.default

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SecondBrainMCP", isDirectory: true)
    }

    @Test("Source root contains only Frontend, Backend, and Shared")
    func sourceRootUsesArchitecturalLayers() throws {
        let entries = try fileManager.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        let directories = try entries
            .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
            .map(\.lastPathComponent)

        #expect(Set(directories) == ["Frontend", "Backend", "Shared"])
    }

    @Test("Only Frontend may import MCP")
    func backendAndSharedDoNotImportMCP() throws {
        let forbiddenImports = try forbiddenImportOccurrences(
            layers: ["Backend", "Shared"],
            imports: ["import MCP"]
        )

        #expect(forbiddenImports.isEmpty, "Forbidden imports: \(forbiddenImports)")
    }

    @Test("Shared remains free of feature frameworks")
    func sharedHasNoFeatureFrameworkDependencies() throws {
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

    @Test("Shared file-domain enums remain separated")
    func sharedFileDomainEnumsStaySeparated() throws {
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

    @Test("Shared file requests remain grouped by CRUD operation")
    func sharedFileRequestsStayGroupedByOperation() throws {
        let expectedDeclarations = [
            "CreateFileRequest.swift": ["struct CreateFileRequest"],
            "ReadFileRequest.swift": ["struct ReadFileOptions", "struct ReadFileRequest"],
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

    @Test("Format operations remain persistence-free")
    func formatOperationsDoNotOwnStorage() throws {
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

    @Test("File resource policy remains backend-owned")
    func fileSizePolicyStaysInBackend() throws {
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

    @Test("Backend composition has one root")
    func backendCompositionIsCentralized() throws {
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

    @Test("Application entry point owns backend startup")
    func applicationEntryOwnsBackendStartup() throws {
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

    @Test("Server configuration remains frontend-owned")
    func serverConfigurationStaysInFrontend() throws {
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

    @Test("File routing delegates transaction mechanics")
    func fileRoutingDoesNotOwnTransactionMechanics() throws {
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

    @Test("File service delegates binding resolution to the catalog")
    func fileServiceDelegatesBindingResolution() throws {
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

    @Test("Backend audit types do not leak across layer boundaries")
    func backendAuditTypesStayInBackend() throws {
        var occurrences: [String] = []

        for layer in ["Frontend", "Shared"] {
            let directory = sourceRoot.appendingPathComponent(layer, isDirectory: true)
            for fileURL in try swiftFiles(under: directory) {
                let lines = try String(contentsOf: fileURL, encoding: .utf8)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                for (index, line) in lines.enumerated() where line.contains("AuditLogger") {
                    let relativePath = fileURL.path.replacingOccurrences(
                        of: sourceRoot.path + "/",
                        with: ""
                    )
                    occurrences.append("\(relativePath):\(index + 1)")
                }
            }
        }

        #expect(occurrences.isEmpty, "Backend audit types leaked across boundaries: \(occurrences)")
    }

    @Test("Backend routing catalog does not leak across layer boundaries")
    func backendRoutingCatalogStaysInBackend() throws {
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

    @Test("Concrete backend file service does not leak across layer boundaries")
    func concreteFileServiceStaysInBackend() throws {
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

    @Test("File tool controller delegates transport mechanics")
    func fileToolControllerOnlyOrchestrates() throws {
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
