import Foundation
import PDFKit
import Synchronization
import Testing
@testable import second_brain_mcp

@Suite
struct `PDF document navigation` {
    /// Large-document scale used by the historical PDFKit memory regression.
    ///
    /// This is a simulated page count, not an on-disk byte size: the test creates
    /// no PDF data or fixture. Removing the production autorelease pool makes the
    /// test retain all 1,500 pages and fail deterministically.
    private static let memoryRegressionPageCount = 1_500

    @Test
    func `Resolves printed labels to physical pages`() {
        let labels = [1: "i", 2: "ii", 15: "1", 16: "2"]

        #expect(PDFDocumentNavigation.resolvePage(label: "ii", in: labels) == 2)
        #expect(PDFDocumentNavigation.resolvePage(label: "2", in: labels) == 16)
        #expect(PDFDocumentNavigation.resolvePage(label: "missing", in: labels) == nil)
    }

    @Test
    func `Document label lookup stops at its first match`() throws {
        let tracker = PageLifetimeTracker()
        let document = TrackingPDFDocument(pageCount: 1_500, tracker: tracker)

        #expect(try PDFDocumentNavigation.resolvePage(label: "2", in: document) == 2)

        let counts = tracker.counts
        #expect(counts.created == 2)
        #expect(counts.live == 0)
        #expect(counts.peak == 1)
    }

    @Test
    func `Document label lookup reports an incomplete bounded scan`() throws {
        let tracker = PageLifetimeTracker()
        let document = TrackingPDFDocument(pageCount: 100, tracker: tracker)

        #expect(throws: PDFReadError.self) {
            _ = try PDFDocumentNavigation.resolvePage(
                label: "missing",
                in: document,
                maximumPages: 10
            )
        }
        #expect(tracker.counts.created == 10)
        #expect(tracker.counts.live == 0)
    }

    @Test
    func `Empty documents expose no navigation metadata`() throws {
        let document = PDFDocument()

        #expect(PDFDocumentNavigation.pageLabels(in: document) == nil)
        #expect(try PDFDocumentNavigation.outline(in: document) == nil)
    }

    @Test
    func `Outline extraction stops at its entry limit`() throws {
        // Build the outline entirely in memory. The test needs no PDF fixture and
        // can create more bookmarks than the read operation is willing to return.
        let document = PDFDocument()
        let page = PDFPage()
        document.insert(page, at: 0)

        let root = PDFOutline()
        for index in 0..<60 {
            let child = PDFOutline()
            child.label = "Bookmark \(index)"
            child.destination = PDFDestination(page: page, at: .zero)
            root.insertChild(child, at: index)
        }
        document.outlineRoot = root

        let outline = try #require(
            try PDFDocumentNavigation.outline(in: document, maximumEntries: 10)
        )

        #expect(outline.count == 10)
        #expect(outline.map(\.title) == (0..<10).map { "Bookmark \($0)" })
        #expect(outline.allSatisfy { $0.pageNumber == 1 })
    }

    @Test
    func `Outline traversal also limits malformed bookmarks`() throws {
        let document = PDFDocument()
        let page = PDFPage()
        document.insert(page, at: 0)

        let root = PDFOutline()
        for index in 0..<20 {
            root.insertChild(PDFOutline(), at: index)
        }
        let valid = PDFOutline()
        valid.label = "Too late"
        valid.destination = PDFDestination(page: page, at: .zero)
        root.insertChild(valid, at: 20)
        document.outlineRoot = root

        #expect(
            try PDFDocumentNavigation.outline(
                in: document,
                maximumEntries: 10,
                maximumVisitedNodes: 10
            ) == nil
        )
    }

    @Test
    func `Page-label scans release PDFKit pages incrementally`() {
        // The document is a lightweight PDFKit test double. Each page access
        // returns a fresh, autoreleased PDFPage, matching the ownership behavior
        // that caused real large PDFs to consume gigabytes during label scans.
        let tracker = PageLifetimeTracker()
        let document = TrackingPDFDocument(
            pageCount: Self.memoryRegressionPageCount,
            tracker: tracker
        )

        #expect(PDFDocumentNavigation.pageLabels(in: document) == nil)

        // The per-page pool must drain every page before the next iteration.
        // Without it, both values become 1,500 instead of zero and one.
        let counts = tracker.counts
        #expect(counts.created == Self.memoryRegressionPageCount)
        #expect(counts.live == 0)
        #expect(counts.peak == 1)
    }
}

private final class TrackingPDFDocument: PDFDocument {
    private let trackedPageCount: Int
    private let tracker: PageLifetimeTracker

    init(pageCount: Int, tracker: PageLifetimeTracker) {
        self.trackedPageCount = pageCount
        self.tracker = tracker
        super.init()
    }

    override var pageCount: Int {
        trackedPageCount
    }

    override func page(at index: Int) -> PDFPage? {
        let page = TrackingPDFPage(pageNumber: index + 1, tracker: tracker)

        // Hold the page until the nearest autoreleasepool drains, just as an
        // Objective-C API returning an autoreleased PDFPage would. The caller gets
        // a non-owning value, so the test observes exactly where that drain occurs.
        return Unmanaged.passRetained(page).autorelease().takeUnretainedValue()
    }
}

private final class TrackingPDFPage: PDFPage {
    private let pageNumber: Int
    private let tracker: PageLifetimeTracker

    init(pageNumber: Int, tracker: PageLifetimeTracker) {
        self.pageNumber = pageNumber
        self.tracker = tracker
        // Creation and deinitialization form the observable lifetime boundary.
        tracker.didCreatePage()
        super.init()
    }

    override var label: String? {
        "\(pageNumber)"
    }

    deinit {
        tracker.didDestroyPage()
    }
}

private final class PageLifetimeTracker: Sendable {
    struct Counts: Sendable {
        var created = 0
        var live = 0
        var peak = 0
    }

    // Tests can run concurrently, so keep lifetime accounting data-race-free.
    private let storage = Mutex(Counts())

    var counts: Counts {
        storage.withLock { $0 }
    }

    func didCreatePage() {
        storage.withLock { counts in
            counts.created += 1
            counts.live += 1
            counts.peak = max(counts.peak, counts.live)
        }
    }

    func didDestroyPage() {
        storage.withLock { counts in
            counts.live -= 1
        }
    }
}
