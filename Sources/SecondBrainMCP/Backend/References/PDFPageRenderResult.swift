/// Bounded page-rendering output and omission facts for one PDF read.
struct PDFPageRenderResult: Sendable {
    /// Successfully rendered pages retained inside the payload budget.
    let pages: [RenderedPDFPage]
    /// Pages PDFKit could not render.
    let renderFailureCount: Int
    /// Renderable pages omitted because the aggregate response budget was full.
    let payloadOmissionCount: Int
    /// Retained pages whose extracted text exceeded the aggregate text budget.
    let textOmissionCount: Int
    /// Conservative text-plus-base64 bytes charged for retained page blocks.
    let retainedPayloadBytes: Int

    /// Empty rendering used when a selector resolves to no page.
    static let empty = PDFPageRenderResult(
        pages: [],
        renderFailureCount: 0,
        payloadOmissionCount: 0,
        textOmissionCount: 0,
        retainedPayloadBytes: 0
    )
}
