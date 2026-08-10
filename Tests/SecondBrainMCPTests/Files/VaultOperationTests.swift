import Testing
@testable import second_brain_mcp

@Suite("Vault operation")
struct VaultOperationTests {
    @Test("File CRUD converts without making directory move a file capability")
    func fileConversions() {
        for fileOperation in FileCRUDOperation.allCases {
            let vaultOperation = VaultOperation(fileOperation)
            #expect(vaultOperation.fileCRUDOperation == fileOperation)
        }
        #expect(VaultOperation.move.fileCRUDOperation == nil)
    }

    @Test("Mutation classification includes directory moves")
    func mutationClassification() {
        #expect(!VaultOperation.read.isMutation)
        for operation in [
            VaultOperation.create, .update, .delete, .move,
        ] {
            #expect(operation.isMutation)
        }
    }
}
