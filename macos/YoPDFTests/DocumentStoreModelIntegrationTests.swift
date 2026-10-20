import PDFKit
import XCTest
@testable import YoPDFCore

/// The reader model no longer owns a security scope itself: it owns a
/// `DocumentSession`. These tests pin that hand-off so the two layers cannot
/// drift back into double ownership.
@MainActor
final class DocumentStoreModelIntegrationTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        temporaryFiles.removeAll()
        super.tearDown()
    }

    private func makeFixture(named name: String) throws -> URL {
        let url = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 2, named: name)
        temporaryFiles.append(url)
        return url
    }

    func testOpenExposesTheSessionThatOwnsTheScope() throws {
        let url = try makeFixture(named: "model-session")
        let spy = SecurityScopeSpy()
        let model = PDFDocumentModel(access: spy)

        XCTAssertTrue(model.open(url: url))

        let session = try XCTUnwrap(model.documentSession)
        XCTAssertEqual(session.url, url)
        XCTAssertEqual(session.version.size, Int64((try Data(contentsOf: url)).count))
        XCTAssertEqual(spy.starts, [url])

        model.close()
        XCTAssertNil(model.documentSession)
        XCTAssertEqual(spy.stops, [url], "closing the document must release exactly one scope")
    }

    func testFailedOpenKeepsThePreviousSession() throws {
        let good = try makeFixture(named: "model-good")
        let corrupt = try PDFFixtureFactory.writeTemporaryFile(
            named: "model-corrupt.pdf",
            contents: Data(repeating: 0x42, count: 2048)
        )
        temporaryFiles.append(corrupt)
        let spy = SecurityScopeSpy()
        let model = PDFDocumentModel(access: spy)

        XCTAssertTrue(model.open(url: good))
        let goodSession = try XCTUnwrap(model.documentSession)

        XCTAssertFalse(model.open(url: corrupt))

        XCTAssertTrue(model.documentSession === goodSession)
        XCTAssertEqual(model.fileURL, good)
        XCTAssertEqual(spy.stops, [corrupt], "only the failed candidate is released")
        model.close()
    }

    /// The bytes written through the model's session are the bytes on disk, and
    /// the file is still a readable PDF afterwards.
    func testSavingThroughTheModelsSessionWritesTheFile() throws {
        let url = try makeFixture(named: "model-save")
        let model = PDFDocumentModel(access: SecurityScopeSpy())
        XCTAssertTrue(model.open(url: url))
        let session = try XCTUnwrap(model.documentSession)

        let original = try session.read()
        try session.save(original)

        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(PDFDocument(url: url)?.pageCount, 2)
        XCTAssertEqual(model.documentSession?.version.contentHash, session.version.contentHash)
        model.close()
    }
}
