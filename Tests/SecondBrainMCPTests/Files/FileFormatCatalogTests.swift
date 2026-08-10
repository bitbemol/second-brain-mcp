import Foundation
import Testing
@testable import second_brain_mcp

@Suite
struct `File format catalog` {
    @Test
    func `Typed binding access resolves each registered CRUD operation`() throws {
        let catalog = makeCatalog()

        #expect(try catalog.createBinding(for: .markdown, in: .notes).allowedAreas == [.notes])
        #expect(try catalog.readBinding(for: .markdown, in: .notes).allowedAreas == [.notes])
        #expect(try catalog.updateBinding(for: .markdown, in: .notes).allowedAreas == [.notes])
        #expect(try catalog.deleteBinding(for: .markdown, in: .notes).allowedAreas == [.notes])
    }

    @Test
    func `Binding access enforces operation area policy`() throws {
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

    @Test
    func `Binding access rejects unregistered formats`() throws {
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
            allowedAreas: [.notes],
            execute: { _, _ in
                PreparedFileWrite(data: Data(), output: .text("create"))
            }
        )
        let read = ReadOperationBinding(
            allowedAreas: [.notes],
            execute: { _, _, _ in .text("read") }
        )
        let update = UpdateOperationBinding(
            allowedAreas: [.notes],
            execute: { _, _, _ in
                PreparedFileWrite(data: Data(), output: .text("update"))
            }
        )
        let delete = DeleteOperationBinding(
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
