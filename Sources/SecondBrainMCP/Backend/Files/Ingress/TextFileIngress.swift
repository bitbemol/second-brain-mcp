import Foundation

/// Ingress gate for inline text and structured file content.
///
/// Arbitrary external paths are deliberately rejected here. Only media create
/// handlers may read external sources because image and video decoding provide
/// a strong content gate. Opaque text imports could otherwise copy unrelated
/// local files into the vault.
struct TextFileIngress: Sendable {
    /// Rejections enforced before a stored-text resolver receives bytes.
    enum IngressError: Error, CustomStringConvertible {
        /// No inline content was supplied.
        case missingContent
        /// An opaque format attempted to read an arbitrary external path.
        case externalSourceNotAllowed

        /// Human-readable ingress-policy failure.
        var description: String {
            switch self {
            case .missingContent:
                return "Inline content is required for this format"
            case .externalSourceNotAllowed:
                return "External source paths are supported only for validated image and video imports"
            }
        }
    }

    /// Converts a stored-text request into validated semantic input.
    ///
    /// - Parameters:
    ///   - request: Caller input whose content and source policy is enforced.
    ///   - target: Validated target supplying the effective concrete format.
    /// - Returns: Bounded UTF-8 data and safe metadata for the format resolver.
    /// - Throws: ``IngressError`` or ``FileResourcePolicy/Violation`` when input
    ///   violates ingress or resource policy.
    func prepare(
        _ request: CreateFileRequest,
        for target: WritableFileTarget
    ) throws -> TextFileCreateInput {
        guard request.source == nil else { throw IngressError.externalSourceNotAllowed }
        guard let content = request.content else { throw IngressError.missingContent }
        let data = Data(content.utf8)
        try FileResourcePolicy.validate(
            bytes: data.count,
            format: target.format,
            path: "inline \(target.format.rawValue) input"
        )
        return TextFileCreateInput(data: data, tags: request.tags)
    }
}
