import Testing
@testable import second_brain_mcp

/// Preserves the original domain-error assertion while checking the persistence phase.
func expectPreparationFailure<E: Error>(
    _ expectedType: E.Type,
    sourceLocation: SourceLocation = #_sourceLocation,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected a failure before persistence", sourceLocation: sourceLocation)
    } catch MutationFailure.beforePersistence(let cause) {
        #expect(cause is E, sourceLocation: sourceLocation)
    } catch {
        Issue.record(
            "Expected a failure before persistence; received \(type(of: error))",
            sourceLocation: sourceLocation
        )
    }
}
