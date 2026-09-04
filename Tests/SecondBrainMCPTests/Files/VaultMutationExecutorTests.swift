import Testing
@testable import second_brain_mcp

@Suite
struct `Vault mutation executor` {
    private actor EventLog {
        private var values: [String] = []

        func append(_ value: String) {
            values.append(value)
        }

        func snapshot() -> [String] {
            values
        }
    }

    private struct VersioningSpy: VaultVersioning {
        let events: EventLog
        var shouldFail = false

        func recordSnapshot() async throws {
            try await record("snapshot")
        }

        func recordSnapshot(changing paths: [String]) async throws {
            try await record("snapshot:" + paths.joined(separator: ","))
        }

        private func record(_ event: String) async throws {
            await events.append(event)
            if shouldFail {
                throw TestFailure.snapshot
            }
        }
    }

    private enum TestFailure: Error {
        case persistence
        case snapshot
    }

    @Test
    func `Persistence finishes before the required Git snapshot`() async throws {
        let events = EventLog()
        let executor = VaultMutationExecutor(
            versioning: VersioningSpy(events: events)
        )
        let output = try await executor.execute(PreparedVaultMutation(
            requiresSnapshot: true,
            perform: {
                await events.append("persistence")
                return .text("saved")
            }
        ))

        #expect(await events.snapshot() == ["persistence", "snapshot"])
        guard case .text(let text) = output.contents.first else {
            Issue.record("Expected text output")
            return
        }
        #expect(text == "saved")
    }

    @Test
    func `Validated mutation paths select the scoped snapshot path`() async throws {
        let events = EventLog()
        let executor = VaultMutationExecutor(
            versioning: VersioningSpy(events: events)
        )

        _ = try await executor.execute(PreparedVaultMutation(
            requiresSnapshot: true,
            snapshotPaths: ["notes/old.md", "notes/new.md"],
            perform: {
                await events.append("persistence")
                return .text("moved")
            }
        ))

        #expect(
            await events.snapshot()
                == ["persistence", "snapshot:notes/old.md,notes/new.md"]
        )
    }

    @Test
    func `Filesystem-only mutations skip Git`() async throws {
        let events = EventLog()
        let executor = VaultMutationExecutor(
            versioning: VersioningSpy(events: events)
        )

        _ = try await executor.execute(PreparedVaultMutation(
            requiresSnapshot: false,
            perform: {
                await events.append("persistence")
                return .text("moved")
            }
        ))

        #expect(await events.snapshot() == ["persistence"])
    }

    @Test
    func `Persistence failure stops before Git`() async {
        let events = EventLog()
        let executor = VaultMutationExecutor(
            versioning: VersioningSpy(events: events)
        )

        await #expect(throws: TestFailure.self) {
            _ = try await executor.execute(PreparedVaultMutation(
                requiresSnapshot: true,
                perform: {
                    await events.append("persistence")
                    throw TestFailure.persistence
                }
            ))
        }
        #expect(await events.snapshot() == ["persistence"])
    }

    @Test
    func `Git failure is returned after persistence`() async {
        let events = EventLog()
        let executor = VaultMutationExecutor(
            versioning: VersioningSpy(events: events, shouldFail: true)
        )

        await #expect(throws: TestFailure.self) {
            _ = try await executor.execute(PreparedVaultMutation(
                requiresSnapshot: true,
                perform: {
                    await events.append("persistence")
                    return .text("saved")
                }
            ))
        }
        #expect(await events.snapshot() == ["persistence", "snapshot"])
    }

    @Test
    func `Cancellation after persistence begins does not skip Git`() async throws {
        let events = EventLog()
        let executor = VaultMutationExecutor(
            versioning: VersioningSpy(events: events)
        )
        let task = Task {
            try await executor.execute(PreparedVaultMutation(
                requiresSnapshot: true,
                perform: {
                    await events.append("persistence")
                    try await Task.sleep(for: .milliseconds(100))
                    return .text("saved")
                }
            ))
        }

        while await events.snapshot().isEmpty {
            await Task.yield()
        }
        task.cancel()

        _ = try await task.value
        #expect(await events.snapshot() == ["persistence", "snapshot"])
    }
}
