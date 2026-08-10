import Testing
@testable import second_brain_mcp

@Suite("Video pixel dimensions")
struct VideoPixelDimensionsTests {
    @Test("Rounds finite geometry and normalizes transformed axes")
    func finiteGeometry() throws {
        let dimensions = try #require(
            VideoPixelDimensions(width: 1920.4, height: -1080.6)
        )

        #expect(dimensions.width == 1920)
        #expect(dimensions.height == 1081)
    }

    @Test("Rejects nonpositive and non-finite geometry")
    func invalidGeometry() {
        #expect(VideoPixelDimensions(width: 0, height: 1080) == nil)
        #expect(VideoPixelDimensions(width: 1920, height: 0.4) == nil)
        #expect(VideoPixelDimensions(width: .nan, height: 1080) == nil)
        #expect(VideoPixelDimensions(width: 1920, height: .infinity) == nil)
    }

    @Test("Rejects values outside Swift integer range")
    func outOfRangeGeometry() {
        #expect(VideoPixelDimensions(width: Double(Int.max), height: 1080) == nil)
        #expect(VideoPixelDimensions(width: -Double.greatestFiniteMagnitude, height: 1080) == nil)
    }
}
