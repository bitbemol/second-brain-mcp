import Testing
@testable import SecondBrainMCP

@Suite("Video frame scheduling")
struct VideoFrameScheduleTests {
    @Test("Short clips use the requested frame rate")
    func shortClip() {
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

    @Test("Long clips spread the frame ceiling across the complete video")
    func longClip() {
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

    @Test("A sub-frame clip still produces one frame")
    func subFrameClip() {
        let schedule = VideoFrameSchedule(
            duration: 0.05,
            framesPerSecond: 10,
            maximumFrames: 120
        )

        #expect(schedule.times == [0])
        #expect(abs(schedule.frameDelay - 0.05) < 1e-9)
    }

    @Test("Zero duration degrades to one frame without NaN")
    func zeroDuration() {
        let schedule = VideoFrameSchedule(
            duration: 0,
            framesPerSecond: 10,
            maximumFrames: 120
        )

        #expect(schedule.times == [0])
        #expect(schedule.frameDelay == 0)
    }
}
