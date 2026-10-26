import XCTest
@testable import YoPDFCore

@MainActor
final class PDFDocumentModelTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        temporaryFiles.removeAll()
        super.tearDown()
    }

    private func makeFixture(pageCount: Int = 3, named name: String = "fixture") throws -> URL {
        let url = try PDFFixtureFactory.writeTemporaryPDF(pageCount: pageCount, named: name)
        temporaryFiles.append(url)
        return url
    }

    // MARK: - Opening

    func testOpenValidPDFLoadsMetadata() throws {
        let url = try makeFixture(pageCount: 4, named: "sample")
        let model = PDFDocumentModel()

        XCTAssertTrue(model.open(url: url))

        XCTAssertTrue(model.isLoaded)
        XCTAssertEqual(model.pageCount, 4)
        XCTAssertEqual(model.currentPageIndex, 0)
        XCTAssertEqual(model.displayPageNumber, 1)
        XCTAssertEqual(model.title, "sample")
        XCTAssertEqual(model.fileURL, url)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.zoomScale, 1)
        XCTAssertTrue(model.isAutoScaling)
    }

    func testOpenValidPDFExposesPageText() throws {
        let url = try makeFixture(pageCount: 2)
        let model = PDFDocumentModel()

        XCTAssertTrue(model.open(url: url))

        let firstPage = try XCTUnwrap(model.document?.page(at: 0))
        let text = try XCTUnwrap(firstPage.string)
        XCTAssertTrue(
            text.contains("Page 1"),
            "Expected extractable text on page 1, got: \(text.debugDescription)"
        )
    }

    func testOpenRejectsNonPDFExtension() throws {
        let url = try PDFFixtureFactory.writeTemporaryFile(
            named: "notes.txt",
            contents: Data("not a pdf".utf8)
        )
        temporaryFiles.append(url)
        let model = PDFDocumentModel()

        XCTAssertFalse(model.open(url: url))
        XCTAssertFalse(model.isLoaded)
        XCTAssertEqual(model.lastError, .unsupportedType("txt"))
    }

    func testOpenRejectsMissingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yopdf-does-not-exist-\(UUID().uuidString).pdf")
        let model = PDFDocumentModel()

        XCTAssertFalse(model.open(url: url))
        XCTAssertEqual(model.lastError, .fileMissing)
    }

    func testOpenRejectsCorruptPDF() throws {
        let url = try PDFFixtureFactory.writeTemporaryFile(
            named: "corrupt.pdf",
            contents: Data(repeating: 0x42, count: 4096)
        )
        temporaryFiles.append(url)
        let model = PDFDocumentModel()

        XCTAssertFalse(model.open(url: url))
        XCTAssertFalse(model.isLoaded)
        XCTAssertTrue(
            model.lastError == .unreadable || model.lastError == .emptyDocument,
            "Expected unreadable/empty, got \(String(describing: model.lastError))"
        )
    }

    func testFailedOpenKeepsPreviousDocument() throws {
        let good = try makeFixture(pageCount: 2, named: "good")
        let bad = try PDFFixtureFactory.writeTemporaryFile(
            named: "bad.txt",
            contents: Data("nope".utf8)
        )
        temporaryFiles.append(bad)

        let model = PDFDocumentModel()
        XCTAssertTrue(model.open(url: good))

        XCTAssertFalse(model.open(url: bad))
        XCTAssertTrue(model.isLoaded)
        XCTAssertEqual(model.pageCount, 2)
        XCTAssertEqual(model.title, "good")
        XCTAssertNotNil(model.lastError)
    }

    // MARK: - Navigation

    func testPageNavigationClampsAtBothEnds() throws {
        let url = try makeFixture(pageCount: 3)
        let model = PDFDocumentModel()
        XCTAssertTrue(model.open(url: url))

        model.goToPreviousPage()
        XCTAssertEqual(model.currentPageIndex, 0, "cannot move before the first page")

        model.goToNextPage()
        model.goToNextPage()
        XCTAssertEqual(model.currentPageIndex, 2)

        model.goToNextPage()
        XCTAssertEqual(model.currentPageIndex, 2, "cannot move past the last page")
    }

    func testPageSteppingAtDocumentBoundariesDoesNotIssueNavigationCommand() throws {
        let url = try makeFixture(pageCount: 3)
        let model = PDFDocumentModel()
        XCTAssertTrue(model.open(url: url))

        let firstPageRevision = model.pageNavigationRevision
        model.goToPreviousPage()
        XCTAssertEqual(model.currentPageIndex, 0)
        XCTAssertEqual(model.pageNavigationRevision, firstPageRevision,
                       "a no-op step at the first page must not issue a navigation command")

        model.goToPage(2)
        let lastPageRevision = model.pageNavigationRevision
        model.goToNextPage()
        XCTAssertEqual(model.currentPageIndex, 2)
        XCTAssertEqual(model.pageNavigationRevision, lastPageRevision,
                       "a no-op step at the last page must not issue a navigation command")
    }

    func testGoToPageClampsOutOfRangeValues() throws {
        let url = try makeFixture(pageCount: 3)
        let model = PDFDocumentModel()
        XCTAssertTrue(model.open(url: url))

        model.goToPage(99)
        XCTAssertEqual(model.currentPageIndex, 2)

        model.goToPage(-5)
        XCTAssertEqual(model.currentPageIndex, 0)
    }

    // MARK: - Zoom

    func testZoomStepsFromFittedScaleAndClamps() throws {
        let url = try makeFixture(pageCount: 1)
        let model = PDFDocumentModel()
        XCTAssertTrue(model.open(url: url))

        // Simulate PDFView reporting its fitted scale.
        model.updateEffectiveScale(1.4)
        XCTAssertTrue(model.isAutoScaling)

        model.zoomIn()
        XCTAssertFalse(model.isAutoScaling)
        XCTAssertEqual(model.zoomScale, 1.75, accuracy: 0.0001)
        XCTAssertEqual(model.zoomScale, model.effectiveScale, accuracy: 0.0001)

        model.setZoomScale(99)
        XCTAssertEqual(model.zoomScale, PDFDocumentModel.maximumZoomScale)

        model.setZoomScale(0.001)
        XCTAssertEqual(model.zoomScale, PDFDocumentModel.minimumZoomScale)
    }

    func testUpdateEffectiveScaleDoesNotLeaveAutoScaling() throws {
        let url = try makeFixture(pageCount: 1)
        let model = PDFDocumentModel()
        XCTAssertTrue(model.open(url: url))

        model.updateEffectiveScale(0.8)
        XCTAssertTrue(model.isAutoScaling)
        XCTAssertEqual(model.zoomScale, 1, "intent must stay untouched while fitting")

        model.fitToWindow()
        XCTAssertTrue(model.isAutoScaling)
    }

    func testResetZoomGoesToActualSize() throws {
        let url = try makeFixture(pageCount: 1)
        let model = PDFDocumentModel()
        XCTAssertTrue(model.open(url: url))

        model.setZoomScale(3)
        model.resetZoom()

        XCTAssertEqual(model.zoomScale, 1, accuracy: 0.0001)
        XCTAssertFalse(model.isAutoScaling)
    }

    func testNonFiniteZoomIsIgnored() throws {
        let url = try makeFixture(pageCount: 1)
        let model = PDFDocumentModel()
        XCTAssertTrue(model.open(url: url))

        model.setZoomScale(.nan)
        XCTAssertEqual(model.zoomScale, 1)
        XCTAssertTrue(model.isAutoScaling)
    }

    // MARK: - Lifecycle

    func testOpeningSecondDocumentResetsCursorAndZoom() throws {
        let first = try makeFixture(pageCount: 5, named: "first")
        let second = try makeFixture(pageCount: 2, named: "second")
        let model = PDFDocumentModel()

        XCTAssertTrue(model.open(url: first))
        model.goToPage(4)
        model.setZoomScale(2.5)

        XCTAssertTrue(model.open(url: second))
        XCTAssertEqual(model.pageCount, 2)
        XCTAssertEqual(model.currentPageIndex, 0)
        XCTAssertEqual(model.zoomScale, 1)
        XCTAssertTrue(model.isAutoScaling)
        XCTAssertEqual(model.title, "second")
    }

    func testCloseResetsEverything() throws {
        let url = try makeFixture(pageCount: 3)
        let model = PDFDocumentModel()
        XCTAssertTrue(model.open(url: url))
        model.goToPage(2)
        model.setZoomScale(2)

        model.close()

        XCTAssertFalse(model.isLoaded)
        XCTAssertNil(model.document)
        XCTAssertNil(model.fileURL)
        XCTAssertEqual(model.pageCount, 0)
        XCTAssertEqual(model.currentPageIndex, 0)
        XCTAssertEqual(model.displayPageNumber, 0)
        XCTAssertEqual(model.title, "")
        XCTAssertTrue(model.isAutoScaling)
        XCTAssertNil(model.lastError)
    }

    func testDismissErrorClearsState() {
        let model = PDFDocumentModel()
        model.open(url: URL(fileURLWithPath: "/definitely/missing.pdf"))
        XCTAssertNotNil(model.lastError)

        model.dismissError()
        XCTAssertNil(model.lastError)
    }
}
