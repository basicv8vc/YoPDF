import AppKit
import PDFKit
import XCTest
@testable import YoPDFCore

@MainActor
final class PDFAnnotationSidebarIndexTests: XCTestCase {

    nonisolated(unsafe) private var temporaryFiles: [URL] = []

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
            let directory = url.deletingLastPathComponent()
            if directory.lastPathComponent.hasPrefix("YoPDFTests-") {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        temporaryFiles.removeAll()
        super.tearDown()
    }

    func testSubtypeNormalizationHandlesSlashPrefixAndCase() {
        XCTAssertEqual(PDFAnnotationTypeName.normalized("Text"), "text")
        XCTAssertEqual(PDFAnnotationTypeName.normalized("/Text"), "text")
        XCTAssertEqual(PDFAnnotationTypeName.normalized(" /HIGHLIGHT "), "highlight")
        XCTAssertNil(PDFAnnotationTypeName.normalized(nil))
        XCTAssertNil(PDFAnnotationTypeName.normalized(" /// "))
    }

    func testSidebarExcludesSlashPrefixedNavigationAndImplementationTypes() {
        for type in ["Link", "/Link", "Popup", "/Popup", "Widget", "/Widget"] {
            XCTAssertTrue(
                PDFAnnotationTypeName.isExcludedFromAnnotationSidebar(type),
                "\(type) should be excluded from the annotation list"
            )
        }
        XCTAssertFalse(PDFAnnotationTypeName.isExcludedFromAnnotationSidebar("/Text"))
        XCTAssertFalse(PDFAnnotationTypeName.isExcludedFromAnnotationSidebar(nil))
    }

    func testReopenedPDFIndexShowsTextPreviewSourceAndOmitsLinks() throws {
        let document = try XCTUnwrap(PDFDocument(data: PDFFixtureFactory.makePDFData(pageCount: 1)))
        let page = try XCTUnwrap(document.page(at: 0))

        let note = PDFAnnotation(
            bounds: CGRect(x: 72, y: 600, width: 24, height: 24),
            forType: .text,
            withProperties: nil
        )
        note.contents = "A saved note preview"
        page.addAnnotation(note)

        let highlight = PDFAnnotation(
            bounds: CGRect(x: 72, y: 560, width: 100, height: 12),
            forType: .highlight,
            withProperties: nil
        )
        page.addAnnotation(highlight)

        let link = PDFAnnotation(
            bounds: CGRect(x: 72, y: 520, width: 100, height: 20),
            forType: .link,
            withProperties: nil
        )
        link.action = PDFActionURL(url: try XCTUnwrap(URL(string: "https://example.com")))
        page.addAnnotation(link)

        let url = try write(document, named: "sidebar-index.pdf")
        let reopened = try XCTUnwrap(PDFDocument(url: url))
        let entries = PDFAnnotationSidebarIndex.entries(in: reopened)

        XCTAssertEqual(entries.count, 2)
        let reopenedNote = try XCTUnwrap(entries.first { PDFAnnotationTypeName.normalized($0.annotation.type) == "text" })
        XCTAssertEqual(reopenedNote.pageIndex, 0)
        XCTAssertEqual(reopenedNote.annotation.contents, "A saved note preview")
        XCTAssertEqual(
            entries.map { PDFAnnotationTypeName.normalized($0.annotation.type) },
            ["text", "highlight"]
        )
    }

    func testRotatedPageStickerNoteRemainsIndexedAfterReopen() throws {
        let document = try XCTUnwrap(PDFDocument(data: PDFFixtureFactory.makePDFData(pageCount: 2)))
        let page = try XCTUnwrap(document.page(at: 1))
        page.rotation = 90

        let note = PDFAnnotation(
            bounds: CGRect(x: 300, y: 400, width: 22, height: 22),
            forType: .text,
            withProperties: nil
        )
        note.contents = "Rotated page note"
        note.setValue(UUID().uuidString, forAnnotationKey: NoteService.identityKey)
        note.setValue("plain", forAnnotationKey: NoteService.styleKey)
        page.addAnnotation(note)

        let url = try write(document, named: "rotated-sidebar-note.pdf")
        let reopened = try XCTUnwrap(PDFDocument(url: url))
        let reopenedPage = try XCTUnwrap(reopened.page(at: 1))
        let entries = PDFAnnotationSidebarIndex.entries(in: reopened)

        XCTAssertEqual(reopenedPage.rotation, 90)
        XCTAssertTrue(NoteService.usesStickerPresentation(try XCTUnwrap(reopenedPage.annotations.first)))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.pageIndex, 1)
        XCTAssertEqual(entries.first?.annotation.contents, "Rotated page note")
    }

    func testIndexCanBuildFor500And1000PageDocuments() throws {
        for pageCount in [500, 1_000] {
            let data = try PDFFixtureFactory.makePDFData(pageCount: pageCount)
            let document = try XCTUnwrap(PDFDocument(data: data))
            let start = ContinuousClock.now
            let entries = PDFAnnotationSidebarIndex.entries(in: document)
            let elapsed = start.duration(to: .now)

            XCTAssertEqual(document.pageCount, pageCount)
            XCTAssertTrue(entries.isEmpty)
            print("Annotation sidebar index for \(pageCount) pages: \(elapsed)")
        }
    }

    private func write(_ document: PDFDocument, named name: String) throws -> URL {
        let data = try XCTUnwrap(document.dataRepresentation())
        let url = try PDFFixtureFactory.writeTemporaryFile(named: name, contents: data)
        temporaryFiles.append(url)
        return url
    }
}
