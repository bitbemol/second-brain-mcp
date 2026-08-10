import Foundation
import Testing
@testable import second_brain_mcp

@Suite("File format catalog")
struct FileFormatCatalogTests {
    @Test("Typed binding access resolves each registered CRUD function")
    func resolvesTypedBindings() throws {
        let catalog = makeCatalog()

        #expect(try catalog.createBinding(for: .markdown, in: .notes).id.rawValue == "markdown")
        #expect(try catalog.readBinding(for: .markdown, in: .notes).id.rawValue == "canvas")
        #expect(try catalog.updateBinding(for: .markdown, in: .notes).id.rawValue == "log")
        #expect(try catalog.deleteBinding(for: .markdown, in: .notes).id.rawValue == "soft_delete")
    }

    @Test("Binding access enforces operation area policy")
    func rejectsDisallowedArea() throws {
        let catalog = makeCatalog()

        do {
            _ = try catalog.readBinding(for: .markdown, in: .references)
            Issue.record("Expected a read policy rejection")
        } catch FileRoutingError.operationNotSupported(let format, let operation, let area) {
            #expect(format == .markdown)
            #expect(operation == .read)
            #expect(area == .references)
        }
    }

    @Test("Binding access rejects unregistered formats")
    func rejectsUnknownFormat() throws {
        let catalog = FileFormatCatalog(definitions: [])

        do {
            _ = try catalog.createBinding(for: .markdown, in: .notes)
            Issue.record("Expected an unknown-format rejection")
        } catch FileRoutingError.unknownFormat(let format) {
            #expect(format == "markdown")
        }
    }

    private func makeCatalog() -> FileFormatCatalog {
        let create = CreateOperationBinding(
            id: .markdown,
            allowedAreas: [.notes],
            execute: { _, _ in
                PreparedFileWrite(data: Data(), output: .text("create"))
            }
        )
        let read = ReadOperationBinding(
            id: .canvas,
            allowedAreas: [.notes],
            execute: { _, _ in .text("read") }
        )
        let update = UpdateOperationBinding(
            id: .log,
            allowedAreas: [.notes],
            execute: { _, _, _ in
                PreparedFileWrite(data: Data(), output: .text("update"))
            }
        )
        let delete = DeleteOperationBinding(
            id: .softDelete,
            allowedAreas: [.notes],
            execute: { _, _ in }
        )
        return FileFormatCatalog(definitions: [
            FileFormatDefinition(
                format: .markdown,
                operations: FormatOperations(
                    create: create,
                    read: read,
                    update: update,
                    delete: delete
                )
            )
        ])
    }
}
