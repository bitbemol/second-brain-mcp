import Testing
@testable import second_brain_mcp

@Suite("Image resource policy")
struct ImageResourcePolicyTests {
    @Test("Accepts dimensions at the configured megapixel boundary")
    func acceptsBoundary() throws {
        let inspection = ImageInspection(
            pixelWidth: 5_000,
            pixelHeight: 10_000,
            format: "png",
            frameCount: 1,
            frameDelays: nil
        )

        try ImageResourcePolicy.validate(inspection, maximumMegapixels: 50)
    }

    @Test("Reports observed and permitted megapixels when dimensions exceed policy")
    func rejectsExcessiveDimensions() {
        let inspection = ImageInspection(
            pixelWidth: 10_000,
            pixelHeight: 10_000,
            format: "png",
            frameCount: 1,
            frameDelays: nil
        )

        do {
            try ImageResourcePolicy.validate(inspection, maximumMegapixels: 50)
            Issue.record("Expected an image resource-policy violation")
        } catch let error as ImageResourcePolicy.ValidationError {
            guard case .tooManyPixels(let megapixels, let limit) = error else {
                Issue.record("Expected tooManyPixels, got \(error)")
                return
            }
            #expect(megapixels == 100)
            #expect(limit == 50)
            #expect(error.description == "Image has too many pixels: 100.0 MP (limit 50 MP)")
        } catch {
            Issue.record("Expected ImageResourcePolicy.ValidationError, got \(error)")
        }
    }

    @Test("Rejects nonpositive dimensions before pixel-count arithmetic")
    func rejectsInvalidDimensions() {
        let inspection = ImageInspection(
            pixelWidth: 0,
            pixelHeight: -1,
            format: "png",
            frameCount: 1,
            frameDelays: nil
        )

        do {
            try ImageResourcePolicy.validate(inspection, maximumMegapixels: 50)
            Issue.record("Expected invalid image dimensions")
        } catch let error as ImageResourcePolicy.ValidationError {
            guard case .invalidDimensions(let width, let height) = error else {
                Issue.record("Expected invalidDimensions, got \(error)")
                return
            }
            #expect(width == 0)
            #expect(height == -1)
        } catch {
            Issue.record("Expected ImageResourcePolicy.ValidationError, got \(error)")
        }
    }

    @Test("Rejects animated sources beyond the metadata frame ceiling")
    func rejectsExcessiveAnimationFrames() {
        let inspection = ImageInspection(
            pixelWidth: 1,
            pixelHeight: 1,
            format: "gif",
            frameCount: 10_001,
            frameDelays: nil
        )

        #expect(throws: ImageResourcePolicy.ValidationError.self) {
            try ImageResourcePolicy.validate(
                inspection,
                maximumMegapixels: 50,
                maximumAnimationFrames: 10_000
            )
        }
    }
}
