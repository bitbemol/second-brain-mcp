import Testing
@testable import SecondBrainMCP

@Suite("PDF page classification")
struct PDFPageClassifierTests {
    @Test("Heading-less title and page-number lists are classified as contents")
    func headinglessContents() {
        let page = """
        Introducing App Architecture 1
        Model View Controller 12
        Model View ViewModel 38
        Coordinators and Navigation 67
        Dependency Injection 103
        Testing Application Boundaries 141
        """

        #expect(PDFPageClassifier.kind(for: page) == .tableOfContents)
    }

    @Test("Heading-less page-range lists are classified as contents")
    func headinglessContentsWithRanges() {
        let page = """
        Introducing App Architecture 1\u{2013}7
        Model View Controller 12-18
        Model View ViewModel 38\u{2014}44
        Coordinators and Navigation 67\u{2013}81
        Dependency Injection 103-119
        Testing Application Boundaries 141\u{2013}156
        """

        #expect(PDFPageClassifier.kind(for: page) == .tableOfContents)
    }

    @Test("Ordinary prose containing numbers remains body content")
    func numberedProse() {
        let page = """
        Model view controller separates responsibilities across three roles.
        The example was revised in 2025.
        A controller coordinates user input with the model and view.
        """

        #expect(PDFPageClassifier.kind(for: page) == .body)
    }
}
