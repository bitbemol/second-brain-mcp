import Testing
@testable import second_brain_mcp

@Suite("Animated image frame sampling")
struct AnimatedImageFrameSamplerTests {
    @Test("Sampling is evenly spaced with first and last included")
    func sampling() {
        #expect(
            AnimatedImageFrameSampler.sampleIndices(total: 5, maximum: 8)
                == [0, 1, 2, 3, 4]
        )
        #expect(
            AnimatedImageFrameSampler.sampleIndices(total: 8, maximum: 8)
                == Array(0..<8)
        )

        let sampled = AnimatedImageFrameSampler.sampleIndices(
            total: 50,
            maximum: 8
        )
        #expect(sampled.count == 8)
        #expect(sampled.first == 0)
        #expect(sampled.last == 49)
        #expect(zip(sampled, sampled.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test("Time offsets sum the delays before a frame")
    func timeOffsets() {
        let delays = [0.1, 0.2, 0.3, 0.4]

        #expect(AnimatedImageFrameSampler.timeOffset(delays: delays, before: 0) == 0)
        #expect(
            abs(AnimatedImageFrameSampler.timeOffset(delays: delays, before: 2) - 0.3)
                < 1e-9
        )
        #expect(
            abs(AnimatedImageFrameSampler.timeOffset(delays: delays, before: 4) - 1.0)
                < 1e-9
        )
        #expect(
            abs(AnimatedImageFrameSampler.timeOffset(delays: delays, before: 99) - 1.0)
                < 1e-9
        )
    }

    @Test("Plan combines selected frames with source timing")
    func plan() {
        let plan = AnimatedImageFrameSampler.plan(
            totalFrames: 4,
            maximumFrames: 3,
            frameDelays: [0.125, 0.25, 0.5, 1.0]
        )

        #expect(plan.selections.map(\.sourceIndex) == [0, 2, 3])
        #expect(plan.selections.map(\.timeOffsetSeconds) == [0, 0.375, 0.875])
        #expect(plan.totalDurationSeconds == 1.875)
    }
}
