import Testing
@testable import SecondBrainMCP

@Suite("Image read planning")
struct ImageReadPlanTests {
    private let limits = ImageLimits.default

    @Test("Native stills within the dimension cap pass through")
    func nativeStillPassesThrough() {
        let plan = ImageReadPlan(
            format: .jpeg,
            inspection: inspection(width: 800, height: 600, format: "jpeg"),
            limits: limits
        )

        #expect(plan.encoding == .sourceBytes(mimeType: "image/jpeg"))
        #expect(plan.passedThrough)
        #expect(plan.selections == [
            AnimatedImageFrameSampler.Selection(
                sourceIndex: 0,
                timeOffsetSeconds: nil
            )
        ])
        #expect(plan.totalFrames == 1)
        #expect(plan.totalDurationSeconds == nil)
    }

    @Test("Oversized and non-native stills use bounded PNG encoding")
    func convertedStillsUsePNG() {
        let oversized = ImageReadPlan(
            format: .png,
            inspection: inspection(width: 5_000, height: 1_000, format: "png"),
            limits: limits
        )
        let nonNative = ImageReadPlan(
            format: .heic,
            inspection: inspection(width: 800, height: 600, format: "heic"),
            limits: limits
        )

        #expect(oversized.encoding == .png(maximumLongEdge: limits.maxLongEdge))
        #expect(nonNative.encoding == .png(maximumLongEdge: limits.maxLongEdge))
        #expect(!oversized.passedThrough)
        #expect(!nonNative.passedThrough)
    }

    @Test("Animated GIFs use sampled PNG frames and retain timing")
    func animatedGIFUsesSampledFrames() {
        let delays = Array(repeating: 0.1, count: 20)
        let plan = ImageReadPlan(
            format: .gif,
            inspection: inspection(
                width: 400,
                height: 300,
                format: "gif",
                frameCount: 20,
                frameDelays: delays
            ),
            limits: limits
        )

        #expect(plan.encoding == .png(maximumLongEdge: limits.gifFrameMaxLongEdge))
        #expect(plan.selections.count == limits.gifMaxFrames)
        #expect(plan.selections.first?.sourceIndex == 0)
        #expect(plan.selections.last?.sourceIndex == 19)
        #expect(plan.totalFrames == 20)
        #expect(abs((plan.totalDurationSeconds ?? 0) - 2) < 0.0001)
    }

    @Test("A single-frame GIF remains a native still")
    func singleFrameGIFPassesThrough() {
        let plan = ImageReadPlan(
            format: .gif,
            inspection: inspection(
                width: 100,
                height: 100,
                format: "gif",
                frameCount: 1
            ),
            limits: limits
        )

        #expect(plan.encoding == .sourceBytes(mimeType: "image/gif"))
        #expect(plan.totalFrames == 1)
        #expect(plan.passedThrough)
    }

    private func inspection(
        width: Int,
        height: Int,
        format: String,
        frameCount: Int = 1,
        frameDelays: [Double]? = nil
    ) -> ImageInspection {
        ImageInspection(
            pixelWidth: width,
            pixelHeight: height,
            format: format,
            frameCount: frameCount,
            frameDelays: frameDelays
        )
    }
}
