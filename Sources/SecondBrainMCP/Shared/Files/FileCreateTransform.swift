/// Explicit transforms supported while creating a file from an external source.
enum FileCreateTransform: String, Codable, Sendable {
    /// Decode an external video and store a sampled animated GIF.
    case videoToGIF = "video_to_gif"
}
