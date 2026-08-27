/// Public caller-input and work ceilings for specialized read operations.
enum FileReadRequestLimits {
    /// Default UTF-8 payload returned by a stored-text read.
    static let defaultTextChunkBytes = 64 * 1_024
    /// Smallest caller-selected text chunk, large enough for one UTF-8 scalar.
    static let minimumTextChunkBytes = 4
    /// Largest UTF-8 payload returned by one stored-text read.
    static let maximumTextChunkBytes = 256 * 1_024
    /// Maximum physical PDF pages returned by one read.
    static let maximumPDFPagesPerRead = 20
    /// Maximum UTF-8 bytes accepted for an inclusive PDF physical-page range.
    static let maximumPDFPageRangeBytes = 64
    /// Aggregate page text retained across one PDF response.
    static let maximumPDFRenderedTextBytes = 8 * 1_024 * 1_024
    /// Conservative MCP text-plus-base64 payload budget for rendered pages.
    static let maximumPDFRenderedPayloadBytes = 32 * 1_024 * 1_024
    /// Space reserved for page headings and MCP envelopes.
    static let PDFRenderedPayloadEnvelopeBytes = 128 * 1_024
}
