import XCTest
@testable import YoPDFCore

/// Verifies the acquire/validate/commit/release lifecycle of security-scoped
/// access, including the case the original implementation got wrong: a failed
/// open must not release the access of the document that stays on screen.
@MainActor
final class DocumentSecurityScopeTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        temporaryFiles.removeAll()
        super.tearDown()
    }

    private func makeFixture(pageCount: Int = 2, named name: String) throws -> URL {
        let url = try PDFFixtureFactory.writeTemporaryPDF(pageCount: pageCount, named: name)
        temporaryFiles.append(url)
        return url
    }

    private func makeCorruptPDF() throws -> URL {
        let url = try PDFFixtureFactory.writeTemporaryFile(
            named: "corrupt-\(UUID().uuidString).pdf",
            contents: Data(repeating: 0x42, count: 4096)
        )
        temporaryFiles.append(url)
        return url
    }

    // MARK: - Successful open

    func testSuccessfulOpenAcquiresScopeAndKeepsIt() throws {
        let url = try makeFixture(named: "scope-open")
        let spy = SecurityScopeSpy()
        let model = PDFDocumentModel(access: spy)

        XCTAssertTrue(model.open(url: url))

        XCTAssertEqual(spy.starts, [url])
        XCTAssertEqual(spy.stops, [], "an open document must keep its access")
    }

    func testSuccessfulSwitchStartsNewScopeBeforeReleasingOldOne() throws {
        let first = try makeFixture(named: "scope-first")
        let second = try makeFixture(named: "scope-second")
        let spy = SecurityScopeSpy()
        let model = PDFDocumentModel(access: spy)

        XCTAssertTrue(model.open(url: first))
        XCTAssertTrue(model.open(url: second))

        XCTAssertEqual(spy.events, [.start(first), .start(second), .stop(first)])
        XCTAssertEqual(model.fileURL, second)
    }

    func testReopeningSameURLBalancesEveryAcquisition() throws {
        let url = try makeFixture(named: "scope-same")
        let spy = SecurityScopeSpy()
        let model = PDFDocumentModel(access: spy)

        XCTAssertTrue(model.open(url: url))
        XCTAssertTrue(model.open(url: url))

        XCTAssertEqual(spy.events, [.start(url), .start(url), .stop(url)])

        model.close()
        XCTAssertEqual(spy.stops.count, 2, "each start must be balanced by one stop")
    }

    // MARK: - Failed open keeps the previous document and its access

    func testFailedOpenKeepsPreviousDocumentAndItsScope() throws {
        let good = try makeFixture(named: "scope-good")
        let bad = try makeCorruptPDF()
        let spy = SecurityScopeSpy()
        let model = PDFDocumentModel(access: spy)

        XCTAssertTrue(model.open(url: good))
        XCTAssertFalse(model.open(url: bad))

        XCTAssertTrue(model.isLoaded)
        XCTAssertEqual(model.fileURL, good)
        XCTAssertEqual(model.title, "scope-good")

        XCTAssertEqual(spy.starts, [good, bad])
        XCTAssertEqual(spy.stops, [bad], "only the candidate scope is released")
        XCTAssertFalse(spy.stops.contains(good), "the displayed document keeps its access")
    }

    func testFailedOpenWithMissingFileDoesNotAcquireAnything() throws {
        let spy = SecurityScopeSpy()
        let model = PDFDocumentModel(access: spy)

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).pdf")
        XCTAssertFalse(model.open(url: missing))

        XCTAssertEqual(spy.events, [], "validation happens before any scope is taken")
    }

    // MARK: - Close and deallocation

    func testCloseReleasesActiveScope() throws {
        let url = try makeFixture(named: "scope-close")
        let spy = SecurityScopeSpy()
        let model = PDFDocumentModel(access: spy)

        XCTAssertTrue(model.open(url: url))
        model.close()

        XCTAssertEqual(spy.stops, [url])
        XCTAssertFalse(model.isLoaded)
    }

    func testCloseIsIdempotent() throws {
        let url = try makeFixture(named: "scope-close-twice")
        let spy = SecurityScopeSpy()
        let model = PDFDocumentModel(access: spy)

        XCTAssertTrue(model.open(url: url))
        model.close()
        model.close()

        XCTAssertEqual(spy.stops, [url], "closing twice must not double-release")
    }

    func testDeallocatingModelReleasesScope() throws {
        let url = try makeFixture(named: "scope-deinit")
        let spy = SecurityScopeSpy()

        var model: PDFDocumentModel? = PDFDocumentModel(access: spy)
        XCTAssertTrue(model?.open(url: url) == true)
        XCTAssertEqual(spy.stops, [])

        model = nil

        XCTAssertEqual(spy.stops, [url], "window close must not leak the scope")
    }

    // MARK: - Sandbox vs non-sandbox

    func testWhenSystemReportsNoScopeNothingIsReleased() throws {
        let url = try makeFixture(named: "scope-non-sandboxed")
        let spy = SecurityScopeSpy()
        spy.startResult = false
        let model = PDFDocumentModel(access: spy)

        XCTAssertTrue(model.open(url: url))
        model.close()

        XCTAssertEqual(spy.starts, [url])
        XCTAssertEqual(spy.stops, [], "a false start has no matching stop")
    }
}
