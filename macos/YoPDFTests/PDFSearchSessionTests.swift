import AppKit
import PDFKit
import XCTest
@testable import YoPDFCore

@MainActor
final class PDFSearchSessionTests: XCTestCase {

    nonisolated(unsafe) private var temporaryFiles: [URL] = []

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: url.path
            )
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        temporaryFiles.removeAll()
        super.tearDown()
    }

    func testLiteralCaseInsensitiveSearchAndWrappedNavigation() async throws {
        let document = try makeDocument(pageCount: 2) { page in
            page == 0
                ? "KV Cache and kv cache; KV-cache is different"
                : "Another KV Cache"
        }
        let session = PDFSearchSession(debounceNanoseconds: 0)

        session.search("kv cache", in: document)
        XCTAssertTrue(session.isSearching, "The UI can report Searching before PDFKit finishes.")
        try await waitForSearchCompletion(session)

        XCTAssertEqual(session.results.count, 3, "Search is case-insensitive and matches literal text.")
        XCTAssertEqual(session.currentResultIndex, 0)

        session.move(by: 1)
        XCTAssertEqual(session.currentResultIndex, 1)
        session.move(by: 10)
        XCTAssertEqual(session.currentResultIndex, 2, "Navigation wraps using the result count.")
        session.move(by: 1)
        XCTAssertEqual(session.currentResultIndex, 0)
        session.move(by: -1)
        XCTAssertEqual(session.currentResultIndex, 2)
    }

    func testRapidInputOnlyPublishesLatestDebouncedQuery() async throws {
        let document = try makeDocument(pageCount: 1) { _ in
            "oldterm and currentterm"
        }
        let session = PDFSearchSession()

        session.search("oldterm", in: document)
        session.search("currentterm", in: document)
        try await waitForSearchCompletion(session)

        XCTAssertEqual(session.query, "currentterm")
        XCTAssertEqual(session.results.count, 1)
        XCTAssertTrue(session.currentSelection?.pages.first?.document === document)
    }

    func testRepeatingTheSameQueryPreservesCurrentResultPosition() async throws {
        let document = try makeDocument(pageCount: 2) { _ in "repeatable hit" }
        let session = PDFSearchSession(debounceNanoseconds: 0)
        session.search("repeatable", in: document)
        try await waitForSearchCompletion(session)
        session.move(by: 1)
        let resultRevision = session.resultsRevision

        session.search("repeatable", in: document)

        XCTAssertEqual(session.currentResultIndex, 1)
        XCTAssertEqual(session.resultsRevision, resultRevision)
    }

    func testSwitchingDocumentDuringActiveSearchRejectsOldHits() async throws {
        let oldDocument = try makeDocument(pageCount: 120) { _ in
            String(repeating: "stalehit ", count: 80)
        }
        let newDocument = try makeDocument(pageCount: 2) { page in
            page == 0 ? "freshneedle" : "freshneedle again"
        }
        let session = PDFSearchSession(debounceNanoseconds: 0)

        session.search("stalehit", in: oldDocument)
        let oldSearchIsActive = await waitUntilFinding(oldDocument)
        XCTAssertTrue(
            oldSearchIsActive,
            "The large fixture should keep PDFKit's asynchronous find active long enough to switch documents."
        )

        session.search("freshneedle", in: newDocument)
        try await waitForSearchCompletion(session)

        XCTAssertEqual(session.query, "freshneedle")
        XCTAssertEqual(session.results.count, 2)
        XCTAssertTrue(session.results.allSatisfy { selection in
            selection.pages.allSatisfy { page in
                newDocument.index(for: page) >= 0 && page.document === newDocument
            }
        }, "Selections from the old document must never be published into the new document's results.")
    }

    func testHighFrequencySearchCompletesAsynchronouslyWithEveryHit() async throws {
        let document = try makeDocument(pageCount: 120) { _ in
            String(repeating: "highfreq ", count: 80)
        }
        let expectedHitCount = (0..<document.pageCount).reduce(into: 0) { count, pageIndex in
            let text = document.page(at: pageIndex)?.string ?? ""
            count += text.components(separatedBy: "highfreq").count - 1
        }
        let session = PDFSearchSession(debounceNanoseconds: 0)

        XCTAssertGreaterThan(expectedHitCount, 1_000)
        session.search("highfreq", in: document)
        let searchWasInFlight = await waitUntilFinding(document)
        XCTAssertTrue(searchWasInFlight, "The large search must be in progress after search() returns.")
        try await waitForSearchCompletion(session)

        XCTAssertEqual(session.results.count, expectedHitCount)
        XCTAssertFalse(session.isSearching)
    }

    func testClearingSearchCancelsDebounceAndRemovesTemporaryResults() async throws {
        let document = try makeDocument(pageCount: 1) { _ in "temporary hit" }
        let session = PDFSearchSession()

        session.search("temporary", in: document)
        session.clear()
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertFalse(session.isSearching)
        XCTAssertTrue(session.results.isEmpty)
        XCTAssertNil(session.currentSelection)
        XCTAssertEqual(session.query, "")
    }

    func testImageOnlyPDFReportsNoMatches() async throws {
        let url = try PDFFixtureFactory.writeTemporaryImagePDF(pixelDimension: 2, named: "scan")
        temporaryFiles.append(url)
        let document = try XCTUnwrap(PDFDocument(url: url))
        let session = PDFSearchSession(debounceNanoseconds: 0)

        session.search("unavailable text", in: document)
        try await waitForSearchCompletion(session)

        XCTAssertTrue(session.results.isEmpty)
        XCTAssertNil(session.currentResultIndex)
        XCTAssertFalse(session.isSearching)
    }

    func testSaveReplacesDocumentAndSearchRebindPreservesHighlightAnnotation() async throws {
        let url = try makeTemporaryPDF(named: "save-search") { _ in
            "KV Cache appears twice: KV Cache"
        }
        let model = PDFDocumentModel(access: SecurityScopeSpy())
        XCTAssertTrue(model.open(url: url))
        let originalDocument = try XCTUnwrap(model.document)
        let session = PDFSearchSession(debounceNanoseconds: 0)

        session.search("KV Cache", in: originalDocument)
        try await waitForSearchCompletion(session)
        XCTAssertEqual(session.results.count, 2)

        model.updateSelection(try XCTUnwrap(session.results.first))
        XCTAssertNotNil(model.addHighlightToSelection())
        XCTAssertEqual(originalDocument.page(at: 0)?.annotations.count, 1)

        session.clear()
        XCTAssertEqual(
            originalDocument.page(at: 0)?.annotations.count,
            1,
            "Clearing temporary search highlights must not remove a persistent PDF annotation."
        )
        session.search("KV Cache", in: originalDocument)
        try await waitForSearchCompletion(session)

        XCTAssertEqual(model.save(), .saved)
        let savedDocument = try XCTUnwrap(model.document)
        XCTAssertFalse(savedDocument === originalDocument, "Manual Save reloads the PDFDocument object.")
        session.documentWasReplaced(with: savedDocument)
        try await waitForSearchCompletion(session)

        XCTAssertEqual(session.results.count, 2)
        XCTAssertTrue(session.results.allSatisfy { selection in
            selection.pages.allSatisfy { $0.document === savedDocument }
        })
        XCTAssertEqual(savedDocument.page(at: 0)?.annotations.count, 1)
    }

    func testSaveAsReplacesDocumentAndRebuildsSearchSelections() async throws {
        let url = try makeTemporaryPDF(named: "save-as-search") { _ in
            "Save As keeps KV Cache searchable"
        }
        let copy = url.deletingLastPathComponent().appendingPathComponent("search-copy.pdf")
        temporaryFiles.append(copy)

        let model = PDFDocumentModel(access: SecurityScopeSpy())
        XCTAssertTrue(model.open(url: url))
        let originalDocument = try XCTUnwrap(model.document)
        let session = PDFSearchSession(debounceNanoseconds: 0)
        session.search("KV Cache", in: originalDocument)
        try await waitForSearchCompletion(session)
        XCTAssertEqual(session.results.count, 1)

        XCTAssertEqual(model.saveAs(to: copy), .saved)
        let copiedDocument = try XCTUnwrap(model.document)
        XCTAssertFalse(copiedDocument === originalDocument)
        session.documentWasReplaced(with: copiedDocument)
        try await waitForSearchCompletion(session)

        XCTAssertEqual(session.results.count, 1)
        XCTAssertTrue(session.results.allSatisfy { $0.pages.allSatisfy { $0.document === copiedDocument } })
        XCTAssertEqual(session.currentResultIndex, 0)
    }

    private func makeDocument(
        pageCount: Int,
        text: @escaping (Int) -> String
    ) throws -> PDFDocument {
        let data = try PDFFixtureFactory.makePDFData(pageCount: pageCount, text: text)
        return try XCTUnwrap(PDFDocument(data: data))
    }

    private func makeTemporaryPDF(
        named name: String,
        text: @escaping (Int) -> String
    ) throws -> URL {
        let url = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 1, named: name, text: text)
        temporaryFiles.append(url)
        return url
    }

    private func waitForSearchCompletion(
        _ session: PDFSearchSession,
        timeout: TimeInterval = 10
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while session.isSearching, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(session.isSearching, "PDFKit search did not finish before the timeout.")
    }

    private func waitUntilFinding(
        _ document: PDFDocument,
        timeout: TimeInterval = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !document.isFinding, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return document.isFinding
    }
}
