import AppKit
import PDFKit
import XCTest
@testable import YoPDFCore

@MainActor
final class AnnotationMarkdownExporterTests: XCTestCase {

    func testExportsMarkupsAndNotesGroupedByPageAndEscapesPlainText() throws {
        let data = try PDFFixtureFactory.makeParagraphData(pageCount: 2, linesPerPage: 2)
        let document = try XCTUnwrap(PDFDocument(data: data))
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Mooncake: #1"]

        let firstPage = try XCTUnwrap(document.page(at: 0))
        let firstSelection = try selection(in: document, pageIndex: 0, from: 0, to: 20)
        try HighlightService.addMarkup(.highlight, from: firstSelection, to: document)

        let secondPage = try XCTUnwrap(document.page(at: 1))
        let secondSelection = try selection(in: document, pageIndex: 1, from: 0, to: 20)
        try HighlightService.addMarkup(.underline, from: secondSelection, to: document)

        let note = PDFAnnotation(
            bounds: CGRect(x: 320, y: 520, width: 24, height: 24),
            forType: .text,
            withProperties: nil
        )
        note.contents = "Use #cache & [draft](https://example.test)."
        NoteService.setExcerpt("A note about page two", on: note)
        secondPage.addAnnotation(note)

        let markdown = AnnotationMarkdownExporter.markdown(for: document, fallbackTitle: "Fallback")

        XCTAssertTrue(markdown.hasPrefix("# Mooncake\\: \\#1"))
        XCTAssertTrue(markdown.contains("## Page 1\n\n> Page 1 line 1"))
        XCTAssertTrue(markdown.contains("## Page 2"))
        XCTAssertTrue(markdown.contains("**Underline**\n\n> Page 2 line 1"))
        XCTAssertTrue(markdown.contains("> A note about page two\n\n💡 Note:"))
        XCTAssertTrue(markdown.contains("Use \\#cache \\& \\[draft\\]\\(https\\:\\/\\/example\\.test\\)\\."))
        XCTAssertLessThan(
            try XCTUnwrap(markdown.range(of: "## Page 1")).lowerBound,
            try XCTUnwrap(markdown.range(of: "## Page 2")).lowerBound
        )
        XCTAssertEqual(firstPage.annotations.filter { MarkupKind(annotation: $0) == .highlight }.count, 1)
    }

    func testExportsFallbackTitleAndIgnoresUnsupportedAnnotations() throws {
        let data = try PDFFixtureFactory.makeParagraphData(pageCount: 1, linesPerPage: 1)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))

        let square = PDFAnnotation(
            bounds: CGRect(x: 300, y: 600, width: 80, height: 40),
            forType: .square,
            withProperties: nil
        )
        square.contents = "This shape is not a reading annotation"
        page.addAnnotation(square)

        let markdown = AnnotationMarkdownExporter.markdown(for: document, fallbackTitle: "Local PDF")

        XCTAssertEqual(markdown, "# Local PDF")
        XCTAssertFalse(markdown.contains("This shape is not a reading annotation"))
    }

    func testExportsPlaceholderWhenMarkupTextCannotBeExtracted() throws {
        let data = try PDFFixtureFactory.makePDFData(pageCount: 1) { _ in "" }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let highlight = PDFAnnotation(
            bounds: CGRect(x: 72, y: 500, width: 120, height: 24),
            forType: .highlight,
            withProperties: nil
        )
        page.addAnnotation(highlight)

        let markdown = AnnotationMarkdownExporter.markdown(for: document, fallbackTitle: "Scanned page")

        XCTAssertTrue(markdown.contains("## Page 1\n\n**Highlight (text unavailable)**"))
    }

    func testEscapesMarkdownStructureAndIndentedLinesInMultilineNote() throws {
        let data = try PDFFixtureFactory.makePDFData(pageCount: 1, text: { _ in "PDF fixture" })
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let note = PDFAnnotation(
            bounds: CGRect(x: 320, y: 520, width: 24, height: 24),
            forType: .text,
            withProperties: nil
        )
        note.contents = "Important hypothesis\n===\n~~Rejected explanation~~\n    indented text\n\tTab-indented text"
        page.addAnnotation(note)

        let markdown = AnnotationMarkdownExporter.markdown(for: document, fallbackTitle: "Notes")

        XCTAssertTrue(markdown.contains(
            "Important hypothesis\n\\=\\=\\=\n\\~\\~Rejected explanation\\~\\~\n&#32;&#32;&#32;&#32;indented text\n&#9;Tab\\-indented text"
        ))
        XCTAssertFalse(markdown.contains("\n===\n"))
        XCTAssertFalse(markdown.contains("\n~~Rejected explanation~~"))
        XCTAssertFalse(markdown.contains("\n    indented text"))
        XCTAssertFalse(markdown.contains("\n\tTab-indented text"))
    }

    func testNormalizesCRLFInMultilineNoteWithoutAddingBlankLines() throws {
        let data = try PDFFixtureFactory.makePDFData(pageCount: 1, text: { _ in "PDF fixture" })
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let note = PDFAnnotation(
            bounds: CGRect(x: 320, y: 520, width: 24, height: 24),
            forType: .text,
            withProperties: nil
        )
        note.contents = "First line\r\nSecond line"
        page.addAnnotation(note)

        let markdown = AnnotationMarkdownExporter.markdown(for: document, fallbackTitle: "Notes")

        XCTAssertTrue(markdown.contains("First line\nSecond line"))
        XCTAssertFalse(markdown.contains("First line\n\nSecond line"))
    }

    private func selection(
        in document: PDFDocument,
        pageIndex: Int,
        from start: Int,
        to end: Int
    ) throws -> PDFSelection {
        let page = try XCTUnwrap(document.page(at: pageIndex))
        let length = (page.string ?? "").count
        return try XCTUnwrap(
            document.selection(
                from: page,
                atCharacterIndex: min(start, length - 1),
                to: page,
                atCharacterIndex: min(end, length)
            )
        )
    }
}
