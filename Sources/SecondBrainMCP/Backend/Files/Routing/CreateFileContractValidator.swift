/// Enforces the create payload contract selected by the format catalog.
enum CreateFileContractValidator {
    /// A caller supplied a missing, conflicting, or unsupported create field.
    enum Violation: Error, CustomStringConvertible, Sendable {
        case requiresContent(FileFormat)
        case requiresSource(FileFormat)
        case unsupportedField(format: FileFormat, field: String)
        case requiresTransform(format: FileFormat, transform: FileCreateTransform)

        var description: String {
            switch self {
            case .requiresContent(let format):
                return "Create contract for '\(format.rawValue)' requires content"
            case .requiresSource(let format):
                return "Create contract for '\(format.rawValue)' requires source"
            case .unsupportedField(let format, let field):
                return "Create contract for '\(format.rawValue)' does not accept \(field)"
            case .requiresTransform(let format, let transform):
                return "Create contract for '\(format.rawValue)' requires transform="
                    + transform.rawValue
            }
        }
    }

    /// Rejects every field not accepted by the registered contract before dispatch.
    static func validate(
        _ request: CreateFileRequest,
        against contract: FileCreateContract
    ) throws {
        switch contract.input {
        case .content:
            guard request.content != nil else {
                throw Violation.requiresContent(request.format)
            }
            guard request.source == nil else {
                throw Violation.unsupportedField(format: request.format, field: "source")
            }
        case .source:
            guard request.source != nil else {
                throw Violation.requiresSource(request.format)
            }
            guard request.content == nil else {
                throw Violation.unsupportedField(format: request.format, field: "content")
            }
        }

        guard contract.acceptsTags || request.tags.isEmpty else {
            throw Violation.unsupportedField(format: request.format, field: "tags")
        }
        if let required = contract.transform {
            guard request.transform == required else {
                throw Violation.requiresTransform(format: request.format, transform: required)
            }
        } else if request.transform != nil {
            throw Violation.unsupportedField(format: request.format, field: "transform")
        }
    }
}
