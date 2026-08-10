import Testing
@testable import second_brain_mcp

@Suite
struct `Vault operation` {
    @Test
    func `File CRUD converts without making directory move a file capability`() {
        for fileOperation in FileCRUDOperation.allCases {
            let vaultOperation = VaultOperation(fileOperation)
            #expect(vaultOperation.fileCRUDOperation == fileOperation)
        }
        #expect(VaultOperation.move.fileCRUDOperation == nil)
    }

    @Test
    func `Mutation classification includes directory moves`() {
        #expect(!VaultOperation.read.isMutation)
        for operation in [
            VaultOperation.create, .update, .delete, .move,
        ] {
            #expect(operation.isMutation)
        }
    }
}
