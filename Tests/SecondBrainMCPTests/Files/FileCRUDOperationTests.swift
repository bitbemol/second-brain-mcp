import Testing
@testable import SecondBrainMCP

@Suite("File CRUD operation")
struct FileCRUDOperationTests {
    @Test("Mutation classification follows storage behavior")
    func mutationClassification() {
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
