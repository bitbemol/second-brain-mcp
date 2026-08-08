import Testing
@testable import SecondBrainMCP

@Suite("PDF read admission")
struct PDFReadAdmissionTests {
    @Test("Only one expensive PDF read runs at a time")
    func serializesReads() async throws {
        let gate = AsyncExclusiveGate()
        let admission = PDFReadAdmission(gate: gate)
        let hold = PDFAdmissionHold()
        let completion = PDFAdmissionCompletion()

        let first = Task {
            try await admission.withPermit {
                await hold.enterAndWait()
                return true
            }
        }
        await hold.waitUntilEntered()
        let second = Task {
            try await admission.withPermit {
                await completion.mark()
                return true
            }
        }
        while await gate.waitingCount == 0,
              !(await completion.completed) {
            await Task.yield()
        }
        #expect(await gate.waitingCount == 1)
        #expect(!(await completion.completed))

        await hold.release()
        #expect(try await first.value)
        #expect(try await second.value)
        #expect(await completion.completed)
    }

    @Test("A full PDF read queue fails with a bounded busy error")
    func rejectsExcessWaiters() async throws {
        let gate = AsyncExclusiveGate(maximumWaiters: 0)
        let admission = PDFReadAdmission(gate: gate)
        let hold = PDFAdmissionHold()
        let first = Task {
            try await admission.withPermit {
                await hold.enterAndWait()
                return true
            }
        }
        await hold.waitUntilEntered()

        await #expect(throws: PDFReadError.self) {
            _ = try await admission.withPermit { true }
        }

        await hold.release()
        #expect(try await first.value)
    }
}

private actor PDFAdmissionHold {
    private var entered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        entered = true
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor PDFAdmissionCompletion {
    private(set) var completed = false
    func mark() { completed = true }
}
