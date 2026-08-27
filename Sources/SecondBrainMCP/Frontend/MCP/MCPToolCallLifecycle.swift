import Foundation
import MCP

/// Owns backend tool tasks until they unwind, even when the SDK receive loop ends.
actor MCPToolCallLifecycle {
    private var closed = false
    private var calls: [UUID: Task<CallTool.Result, Error>] = [:]

    func run(
        _ operation: @escaping @Sendable () async throws -> CallTool.Result
    ) async throws -> CallTool.Result {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let id = UUID()
        let task = Task {
            try Task.checkCancellation()
            return try await operation()
        }
        calls[id] = task
        defer { calls.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Terminal closure rejects late SDK dispatch before it can enter the backend.
    /// Awaiting each owned result also joins cancellation-insensitive persistence.
    func closeAndDrain() async {
        closed = true
        let active = Array(calls.values)
        for task in active { task.cancel() }
        for task in active { _ = await task.result }
    }
}
