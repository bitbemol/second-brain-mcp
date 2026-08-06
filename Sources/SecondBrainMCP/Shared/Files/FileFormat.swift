import Foundation

/// Concrete on-disk formats exposed by the generic file API.
///
/// Semantic roles such as "reference" and "attachment" deliberately do not
/// belong here. The vault area controls access policy; the format controls how
/// bytes are validated, transformed, and rendered.
enum FileFormat: String, CaseIterable, Codable, Sendable {
    /// Markdown text with an `.md` or `.markdown` extension.
    case markdown
    /// JSON Canvas 1.0 content.
    case canvas
    /// HTTP Archive JSON content.
    case har
    /// Unified diff content stored as `.patch` or `.diff`.
    case patch
    /// Append-oriented UTF-8 log content.
    case log
    /// General JavaScript Object Notation content.
    case json
    /// Comma-separated tabular text.
    case csv
    /// Portable Network Graphics image.
    case png
    /// JPEG image stored as `.jpg` or `.jpeg`.
    case jpeg
    /// Graphics Interchange Format image or animation.
    case gif
    /// WebP image.
    case webp
    /// High Efficiency Image format.
    case heic
    /// Tagged Image File Format image.
    case tiff
    /// Bitmap image.
    case bmp
    /// Portable Document Format reference.
    case pdf

    /// Lowercase filename extensions accepted for the format.
    var extensions: Set<String> {
        switch self {
        case .markdown: ["md", "markdown"]
        case .canvas: ["canvas"]
        case .har: ["har"]
        case .patch: ["patch", "diff"]
        case .log: ["log"]
        case .json: ["json"]
        case .csv: ["csv"]
        case .png: ["png"]
        case .jpeg: ["jpg", "jpeg"]
        case .gif: ["gif"]
        case .webp: ["webp"]
        case .heic: ["heic", "heif"]
        case .tiff: ["tif", "tiff"]
        case .bmp: ["bmp"]
        case .pdf: ["pdf"]
        }
    }

    /// Whether the format is handled by the shared image operation family.
    var isImage: Bool {
        switch self {
        case .png, .jpeg, .gif, .webp, .heic, .tiff, .bmp: true
        default: false
        }
    }

    /// Resolves an image encoder's format identifier to its concrete file format.
    ///
    /// The lookup derives from ``extensions`` so aliases such as `jpg`, `heif`,
    /// and `tif` cannot drift from path validation or require a second registry.
    ///
    /// - Parameter identifier: Case-insensitive image format or extension name.
    /// - Returns: The matching concrete image format, or `nil` when unsupported.
    static func imageFormat(matching identifier: String) -> FileFormat? {
        let normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return allCases.first {
            $0.isImage && $0.extensions.contains(normalized)
        }
    }

    /// Determines whether a path's extension represents this format.
    ///
    /// - Parameter path: A vault-relative or absolute filename.
    /// - Returns: `true` when the lowercase extension belongs to ``extensions``.
    func accepts(path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }
}
