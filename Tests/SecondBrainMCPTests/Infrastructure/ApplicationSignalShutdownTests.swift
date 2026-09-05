import Darwin
import Foundation
import Testing
@testable import second_brain_mcp

/// Runs the built application, not an in-process approximation of main.swift.
@Suite("Application signal shutdown", .serialized)
struct ApplicationSignalShutdownTests {
    @Test("Termination signals drain stalled recovery before normal server exit",
          arguments: [SIGTERM, SIGINT, SIGHUP], [false, true])
    func terminationReapsRecoveryChild(terminationSignal: Int32, discardDiagnostics: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApplicationSignalShutdownTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("notes"), withIntermediateDirectories: true
        )
        let storage = try VaultDataDirectory.prepare(vaultPath: root.path)
        defer {
            try? FileManager.default.removeItem(at: storage.rootURL)
            try? FileManager.default.removeItem(at: root)
        }
        // Give recovery enough real work to observe its child without production test hooks.
        try Data(repeating: 0x61, count: 64 * 1_024 * 1_024)
            .write(to: root.appendingPathComponent("notes/fixture.log"))
        let executable = Bundle(for: ApplicationSignalBundle.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("second-brain-mcp")
        try #require(FileManager.default.isExecutableFile(atPath: executable.path))
        let server = Process()
        let input = Pipe()
        let diagnosticURL = root.appendingPathComponent("stderr.txt")
        try Data().write(to: diagnosticURL)
        let diagnosticFile = try FileHandle(forWritingTo: diagnosticURL)
        defer { try? diagnosticFile.close() }
        server.executableURL = executable
        server.arguments = ["--vault", root.path]
        server.standardInput = input
        server.standardOutput = FileHandle.nullDevice
        server.standardError = discardDiagnostics ? FileHandle.nullDevice : diagnosticFile
        try server.run()
        defer {
            if server.isRunning {
                Darwin.kill(server.processIdentifier, SIGKILL)
                server.waitUntilExit()
            }
        }
        let child = try await stoppedGitChild(of: server.processIdentifier)
        defer {
            // The start identity prevents cleanup from signalling a recycled PID.
            if child.isAlive { Darwin.kill(child.pid, SIGKILL) }
        }
        #expect(Darwin.kill(server.processIdentifier, terminationSignal) == 0)
        // A watchdog, not a benchmark: leave room for the full parallel Xcode plan.
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while (server.isRunning || child.isAlive), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!child.isAlive, "Server termination abandoned a stopped Git child")
        #expect(!server.isRunning, "Server did not finish bounded recovery teardown")
        if !server.isRunning {
            #expect(server.terminationReason == .exit, "SIGTERM bypassed application cleanup")
            let stderr = try String(contentsOf: diagnosticURL, encoding: .utf8)
            #expect(server.terminationStatus == 0, "\(stderr)")
        }
    }

    private func stoppedGitChild(of parent: pid_t) async throws -> ObservedChild {
        // File-heavy tests can occupy the cooperative pool. Observe the short-lived
        // real child on a dedicated test thread so suspension does not depend on it.
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                do { continuation.resume(returning: try Self.stopGitChild(of: parent)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func stopGitChild(of parent: pid_t) throws -> ObservedChild {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            var identifiers = [pid_t](repeating: 0, count: 32)
            let count = identifiers.withUnsafeMutableBytes {
                proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), $0.baseAddress, Int32($0.count))
            }
            for pid in identifiers.prefix(max(0, Int(count)) / MemoryLayout<pid_t>.size) where pid > 0 {
                guard let before = ObservedChild.capture(pid), before.parent == parent else { continue }
                var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
                let length = proc_pidpath(pid, &path, UInt32(path.count))
                guard length > 0, URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).lastPathComponent == "git" else {
                    continue
                }
                guard Darwin.kill(pid, SIGSTOP) == 0 else { continue }
                // A child can exit between discovery and SIGSTOP; accept only a confirmed stop.
                for _ in 0..<50 {
                    if let after = ObservedChild.capture(pid), after.sameProcess(as: before),
                       after.status == UInt32(SSTOP) {
                        return after
                    }
                    Thread.sleep(forTimeInterval: 0.001)
                }
                if before.isAlive { Darwin.kill(pid, SIGCONT) }
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        throw CocoaError(.executableRuntimeMismatch)
    }
}

private final class ApplicationSignalBundle: NSObject {}

private struct ObservedChild {
    let pid: pid_t
    let parent: pid_t
    let seconds: UInt64
    let microseconds: UInt64
    let status: UInt32

    static func capture(_ pid: pid_t) -> Self? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else { return nil }
        return Self(pid: pid, parent: pid_t(info.pbi_ppid),
                    seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec,
                    status: info.pbi_status)
    }

    func sameProcess(as other: Self) -> Bool {
        pid == other.pid && seconds == other.seconds && microseconds == other.microseconds
    }

    var isAlive: Bool {
        Self.capture(pid).map { sameProcess(as: $0) } ?? false
    }
}
