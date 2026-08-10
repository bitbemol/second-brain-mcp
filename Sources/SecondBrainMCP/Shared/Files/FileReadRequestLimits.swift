/// Public caller-input and work ceilings for specialized read operations.
enum FileReadRequestLimits {
    /// Maximum UTF-8 bytes accepted for a printed PDF page label.
    static let maximumPDFBookPageBytes = 512
    /// Maximum UTF-8 bytes accepted for a PDF physical-page range.
    static let maximumPDFPageRangeBytes = 64
    /// Aggregate raw page text retained across one rendered PDF response.
    static let maximumPDFRenderedTextBytes = 8 * 1_024 * 1_024
    /// Conservative MCP text-plus-base64 payload budget for rendered pages.
    static let maximumPDFRenderedPayloadBytes = 32 * 1_024 * 1_024
    /// Space reserved for bounded title, outline, status, and MCP envelopes.
    static let PDFRenderedPayloadEnvelopeBytes = 128 * 1_024
}
