import Testing
@testable import second_brain_mcp

@Suite
struct `File CRUD operation` {
    @Test
    func `Mutation classification follows storage behavior`() {
        for operation in [
            FileCRUDOperation.create,
            .update,
            .delete,
        ] {
            #expect(operation.isMutation)
        }
        #expect(!FileCRUDOperation.read.isMutation)
        #expect(FileCRUDOperation.allCases == [.create, .read, .update, .delete])
    }
}
