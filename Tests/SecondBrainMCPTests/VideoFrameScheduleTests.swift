import Testing
@testable import second_brain_mcp

@Suite
struct `Video frame scheduling` {
    @Test
    func `Short clips use the requested frame rate`() {
        let schedule = VideoFrameSchedule(
            duration: 2,
            framesPerSecond: 10,
            maximumFrames: 120
        )

        #expect(schedule.times.count == 20)
        #expect(abs(schedule.frameDelay - 0.1) < 1e-9)
        #expect(schedule.times.first == 0)
        #expect(schedule.times.last! < 2)
        #expect(abs(schedule.times[1] - 0.1) < 1e-9)
    }

    @Test
    func `Long clips spread the frame ceiling across the complete video`() {
        let schedule = VideoFrameSchedule(
            duration: 100,
            framesPerSecond: 10,
            maximumFrames: 120
        )

        #expect(schedule.times.count == 120)
        #expect(abs(schedule.frameDelay - 100.0 / 120.0) < 1e-9)
        #expect(schedule.times.first == 0)
        #expect(schedule.times.last! < 100)
        #expect(schedule.times.last! > 99)
    }

    @Test
    func `A sub-frame clip still produces one frame`() {
        let schedule = VideoFrameSchedule(
            duration: 0.05,
            framesPerSecond: 10,
            maximumFrames: 120
        )

        #expect(schedule.times == [0])
        #expect(abs(schedule.frameDelay - 0.05) < 1e-9)
    }

    @Test
    func `Zero duration degrades to one frame without NaN`() {
        let schedule = VideoFrameSchedule(
            duration: 0,
            framesPerSecond: 10,
            maximumFrames: 120
        )

        #expect(schedule.times == [0])
        #expect(schedule.frameDelay == 0)
    }
}
