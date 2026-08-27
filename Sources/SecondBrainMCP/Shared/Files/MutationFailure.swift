/// Explicit failure stage supplied by the owner of preparation and persistence.
/// A recognizable underlying error alone never proves that bytes were unchanged.
enum MutationFailure: Error {
    case beforePersistence(any Error)
    case afterPersistenceStarted(any Error)

    var underlying: any Error {
        switch self {
        case .beforePersistence(let error), .afterPersistenceStarted(let error):
            error
        }
    }
}
