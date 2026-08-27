import Foundation

/// Request-wide attempted work is never refunded when an individual document fails.
/// Synchronous format frameworks share this small counter with the asynchronous scan.
final class SearchWorkBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingAtoms = SearchRequestLimits.maximumAtoms

    func consumeAtoms(_ count: Int = 1) throws {
        try Task.checkCancellation()
        try lock.withLock {
            guard count >= 0, count <= remainingAtoms else {
                throw VaultSearchRequestError.workBudgetExceeded
            }
            remainingAtoms -= count
        }
    }
}
