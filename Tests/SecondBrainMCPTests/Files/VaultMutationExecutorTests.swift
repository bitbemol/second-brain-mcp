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
        var shouldFailPreflight = false

        func prepareForMutation(changing paths: [String]?) async throws {
            let scope = paths.map { ":" + $0.joined(separator: ",") } ?? ""
            await events.append("preflight" + scope)
            if shouldFailPreflight {
                throw TestFailure.snapshot
            }
        }

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

    private actor FailOncePostSnapshot: VaultVersioning {
        let events: EventLog
        private var shouldFail = true

        init(events: EventLog) {
            self.events = events
        }

        func prepareForMutation(changing paths: [String]?) async throws {
            await events.append("preflight")
        }

        func recordSnapshot() async throws {
            try await recordPostSnapshot()
        }

        func recordSnapshot(changing paths: [String]) async throws {
            try await recordPostSnapshot()
        }

        private func recordPostSnapshot() async throws {
            await events.append("snapshot")
            if shouldFail {
                shouldFail = false
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

        #expect(await events.snapshot() == ["preflight", "persistence", "snapshot"])
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
                == [
                    "preflight:notes/old.md,notes/new.md",
                    "persistence",
                    "snapshot:notes/old.md,notes/new.md",
                ]
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
    func `Preflight snapshot failure stops before persistence`() async {
        let events = EventLog()
        let executor = VaultMutationExecutor(
            versioning: VersioningSpy(
                events: events,
                shouldFailPreflight: true
            )
        )

        await #expect(throws: MutationFailure.self) {
            _ = try await executor.execute(PreparedVaultMutation(
                requiresSnapshot: true,
                snapshotPaths: ["notes/pending.md"],
                perform: {
                    await events.append("persistence")
                    return .text("saved")
                }
            ))
        }
        #expect(await events.snapshot() == ["preflight:notes/pending.md"])
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
        #expect(await events.snapshot() == ["preflight", "persistence"])
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
        #expect(await events.snapshot() == ["preflight", "persistence", "snapshot"])
    }

    @Test
    func `A mutation after post snapshot failure still preflights current bytes`() async throws {
        let events = EventLog()
        let executor = VaultMutationExecutor(
            versioning: FailOncePostSnapshot(events: events)
        )

        await #expect(throws: TestFailure.self) {
            _ = try await executor.execute(PreparedVaultMutation(
                requiresSnapshot: true,
                snapshotPaths: ["notes/pending.md"],
                perform: {
                    await events.append("persist-B")
                    return .text("B")
                }
            ))
        }
        _ = try await executor.execute(PreparedVaultMutation(
            requiresSnapshot: true,
            snapshotPaths: ["notes/pending.md"],
            perform: {
                await events.append("persist-C")
                return .text("C")
            }
        ))

        #expect(
            await events.snapshot()
                == [
                    "preflight", "persist-B", "snapshot",
                    "preflight", "persist-C", "snapshot",
                ]
        )
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
        #expect(await events.snapshot() == ["preflight", "persistence", "snapshot"])
    }
}
