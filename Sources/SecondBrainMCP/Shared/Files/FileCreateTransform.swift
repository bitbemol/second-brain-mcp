/// Explicit transforms supported while creating a file from an external source.
enum FileCreateTransform: String, CaseIterable, Codable, Hashable, Sendable {
    /// Decode an external video and store a sampled animated GIF.
    case videoToGIF = "video_to_gif"
}
