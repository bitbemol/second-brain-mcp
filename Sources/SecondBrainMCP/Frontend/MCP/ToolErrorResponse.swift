import MCP

/// Final byte ceiling for already-audited tool diagnostics, never for successful content.
enum ToolErrorResponse {
    static let maximumMessageBytes = 1_024

    static func boundedMessage(_ message: String) -> String {
        guard message.utf8.count <= maximumMessageBytes else {
            return "Operation failed; diagnostic details exceed the safe response limit."
        }
        return message
    }

    static func failure(_ message: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: boundedMessage(message), annotations: nil, _meta: nil)],
            isError: true
        )
    }
}
