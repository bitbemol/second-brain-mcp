import Foundation
import Testing
@testable import SecondBrainMCP

@Suite("Vault operation coordinator tree moves")
struct VaultOperationCoordinatorTests {
    @Test("A directory move excludes note reads until the subtree rename completes")
    func treeMoveExcludesReads() async throws {
        let root = NSTemporaryDirectory() + "VaultOperationCoordinatorTests-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(
            atPath: root + "/notes",
            withIntermediateDirectories: true
        )
        try "safe".write(
            toFile: root + "/notes/a.md",
            atomically: true,
            encoding: .utf8
        )
        let locks = URL(fileURLWithPath: root).appendingPathComponent("locks")
        try FileManager.default.createDirectory(
            at: locks.appendingPathComponent("paths", isDirectory: true),
            withIntermediateDirectories: true
        )
        let coordinator = VaultOperationCoordinator(lockDirectoryURL: locks)
        let target = try ReadableFileTarget.resolve(
            path: "notes/a.md",
            format: .markdown,
            vaultPath: root
        )
        let hold = TreeMoveHold()
        let read = TreeMoveReadProbe()

        let writer = Task {
            try await coordinator.withTreeWrite {
                await hold.enterAndWait()
            }
        }
        await hold.waitUntilEntered()
        let reader = Task {
            try await coordinator.withRead(target: target) {
                await read.markEntered()
            }
        }
        while await coordinator.waitingTreeOperationCount == 0 {
            await Task.yield()
        }
        #expect(await read.entered == false)

        await hold.release()
        try await writer.value
        try await reader.value
        #expect(await read.entered)
    }
}

private actor TreeMoveHold {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor TreeMoveReadProbe {
    private(set) var entered = false
    func markEntered() { entered = true }
}
