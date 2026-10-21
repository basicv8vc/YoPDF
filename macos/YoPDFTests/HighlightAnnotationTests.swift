import AppKit
import PDFKit
import XCTest
@testable import YoPDFCore

/// Real PDFKit tests for highlight creation.
///
/// Nothing here mocks PDFKit: the fixture is a generated PDF with real text, the
/// selection is a real `PDFSelection`, and the assertions are made both on the
/// live annotations and on the bytes written to disk — the latter is what other
/// readers actually consume.
@MainActor
final class HighlightAnnotationTests: XCTestCase {

    /// `tearDown()` is nonisolated in XCTest, so the cleanup list cannot be
    /// main-actor isolated. Tests run serially; nothing else touches it.
    nonisolated(unsafe) private var temporaryFiles: [URL] = []

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        temporaryFiles.removeAll()
        super.tearDown()
    }

    private func makeFixture(
        pageCount: Int = 2,
        linesPerPage: Int = 4,
        named name: String = "highlight"
    ) throws -> URL {
        let url = try PDFFixtureFactory.writeTemporaryParagraphPDF(
            pageCount: pageCount,
            linesPerPage: linesPerPage,
            named: name
        )
        temporaryFiles.append(url)
        return url
    }

    /// Selects whole characters on one page, by index into the page's text.
    private func select(
        _ document: PDFDocument,
        pageIndex: Int,
        from start: Int,
        to end: Int
    ) throws -> PDFSelection {
        let page = try XCTUnwrap(document.page(at: pageIndex))
        let length = (page.string ?? "").count
        let lower = min(max(start, 0), length)
        let upper = min(max(end, lower + 1), length)
        return try XCTUnwrap(
            document.selection(from: page, atCharacterIndex: lower, to: page, atCharacterIndex: upper),
            "could not build a selection for \(lower)..<\(upper)"
        )
    }

    /// Selects the entire text of one page.
    ///
    /// Whole-page selections avoid depending on how PDFKit maps character
    /// indices to visual lines when a line is too wide for the page.
    private func selectWholePage(_ document: PDFDocument, pageIndex: Int) throws -> PDFSelection {
        let page = try XCTUnwrap(document.page(at: pageIndex))
        let length = (page.string ?? "").count
        return try XCTUnwrap(
            document.selection(from: page, atCharacterIndex: 0, to: page, atCharacterIndex: length)
        )
    }

    // MARK: - One line

    func testSingleLineHighlightIsAStandardHighlightAnnotation() throws {
        let url = try makeFixture()
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))

        let selection = try select(document, pageIndex: 0, from: 0, to: 12)
        let expected = selection.bounds(for: page)
        XCTAssertFalse(expected.isEmpty)

        let summary = try HighlightService.addHighlight(from: selection, to: document)

        XCTAssertEqual(summary.pageIndices, [0])
        XCTAssertEqual(summary.annotationCount, 1)
        XCTAssertEqual(summary.quadCount, 1)
        XCTAssertEqual(page.annotations.count, 1)

        let annotation = try XCTUnwrap(page.annotations.first)
        XCTAssertTrue(annotation.isHighlightMarkup)
        XCTAssertEqual(annotation.bounds.minX, expected.minX, accuracy: 0.5)
        XCTAssertEqual(annotation.bounds.minY, expected.minY, accuracy: 0.5)
        XCTAssertEqual(annotation.bounds.width, expected.width, accuracy: 0.5)
        XCTAssertEqual(annotation.bounds.height, expected.height, accuracy: 0.5)
        XCTAssertEqual(annotation.quadrilateralPoints?.count, 4)

        let color = try XCTUnwrap(annotation.color.usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent, 1.0, accuracy: 0.02)
        XCTAssertEqual(color.greenComponent, 0.8, accuracy: 0.02)
        XCTAssertEqual(color.blueComponent, 0.0, accuracy: 0.02)
        XCTAssertEqual(color.alphaComponent, 1.0, accuracy: 0.02)
    }

    // MARK: - Several lines

    func testMultiLineSelectionBecomesOneAnnotationWithOneQuadPerLine() throws {
        let url = try makeFixture(pageCount: 1, linesPerPage: 2)
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))

        let selection = try selectWholePage(document, pageIndex: 0)
        let lineRects = HighlightService.lineRects(for: selection, on: page)
        XCTAssertEqual(lineRects.count, 2, "the fixture selection must span exactly two lines")

        let summary = try HighlightService.addHighlight(from: selection, to: document)

        XCTAssertEqual(summary.annotationCount, 1, "one annotation, not one per line")
        XCTAssertEqual(summary.quadCount, 2)
        XCTAssertEqual(page.annotations.count, 1)

        let annotation = try XCTUnwrap(page.annotations.first)
        XCTAssertTrue(annotation.isHighlightMarkup)
        XCTAssertEqual(annotation.quadrilateralPoints?.count, 8)

        // The bounds cover both lines, and the second line is longer: a
        // rectangle-only highlight would paint the empty area to the right of
        // the short first line.
        let union = lineRects.dropFirst().reduce(lineRects[0]) { $0.union($1) }
        XCTAssertEqual(annotation.bounds.minY, union.minY, accuracy: 0.5)
        XCTAssertEqual(annotation.bounds.maxY, union.maxY, accuracy: 0.5)
        XCTAssertEqual(annotation.bounds.width, union.width, accuracy: 0.5)
        XCTAssertGreaterThan(lineRects[1].width, lineRects[0].width)
    }

    func testQuadPointsAreWrittenInPageSpaceAndZOrder() throws {
        let url = try makeFixture(pageCount: 1, linesPerPage: 2)
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))

        let selection = try selectWholePage(document, pageIndex: 0)
        let rects = HighlightService.lineRects(for: selection, on: page)
        XCTAssertEqual(rects.count, 2)

        try HighlightService.addHighlight(from: selection, to: document)

        let data = try XCTUnwrap(document.dataRepresentation())
        let quads = RawPDFInspector.quadPointArrays(in: data)
        XCTAssertEqual(quads.count, 1, "one /QuadPoints array for the one annotation")
        let points = try XCTUnwrap(quads.first)
        // Eight numbers per quad: two corners per line edge, four points.
        XCTAssertEqual(points.count, rects.count * 8)

        // PDFKit converts the annotation-relative points back to page space, and
        // that is what every other reader sees. Each quad is upper-left,
        // upper-right, lower-left, lower-right.
        for (index, rect) in rects.enumerated() {
            let base = index * 8
            XCTAssertEqual(points[base + 0], rect.minX, accuracy: 0.05)
            XCTAssertEqual(points[base + 1], rect.maxY, accuracy: 0.05)
            XCTAssertEqual(points[base + 2], rect.maxX, accuracy: 0.05)
            XCTAssertEqual(points[base + 3], rect.maxY, accuracy: 0.05)
            XCTAssertEqual(points[base + 4], rect.minX, accuracy: 0.05)
            XCTAssertEqual(points[base + 5], rect.minY, accuracy: 0.05)
            XCTAssertEqual(points[base + 6], rect.maxX, accuracy: 0.05)
            XCTAssertEqual(points[base + 7], rect.minY, accuracy: 0.05)
        }
    }

    // MARK: - Across pages

    func testCrossPageSelectionAnnotatesEachPageOnceAndOnlyOnce() throws {
        let url = try makeFixture(pageCount: 2, linesPerPage: 4)
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page0 = try XCTUnwrap(document.page(at: 0))
        let page1 = try XCTUnwrap(document.page(at: 1))

        let page0Length = (page0.string ?? "").count
        let page1Length = (page1.string ?? "").count
        let selection = try XCTUnwrap(
            document.selection(
                from: page0,
                atCharacterIndex: page0Length - 20,
                to: page1,
                atCharacterIndex: min(60, page1Length - 1)
            )
        )
        XCTAssertEqual(selection.pages.count, 2, "the fixture selection must span two pages")

        let page1LineRects = HighlightService.lineRects(for: selection, on: page1)
        XCTAssertFalse(page1LineRects.isEmpty)

        let summary = try HighlightService.addHighlight(from: selection, to: document)

        XCTAssertEqual(summary.pageIndices, [0, 1])
        XCTAssertEqual(summary.annotationCount, 2)
        XCTAssertEqual(page0.annotations.count, 1)
        XCTAssertEqual(page1.annotations.count, 1)

        // The page-1 annotation must cover page-1 geometry only. Its rectangles
        // are expressed in page-1 space, so they cannot be page-0 coordinates
        // that leaked across.
        let annotation1 = try XCTUnwrap(page1.annotations.first)
        XCTAssertTrue(annotation1.isHighlightMarkup)
        let union1 = page1LineRects.dropFirst().reduce(page1LineRects[0]) { $0.union($1) }
        XCTAssertEqual(annotation1.bounds.minY, union1.minY, accuracy: 0.5)
        XCTAssertEqual(annotation1.bounds.maxY, union1.maxY, accuracy: 0.5)
        XCTAssertLessThanOrEqual(annotation1.bounds.maxY, page1.bounds(for: .mediaBox).maxY)

        let annotation0 = try XCTUnwrap(page0.annotations.first)
        XCTAssertTrue(annotation0.isHighlightMarkup)
        // Each annotation belongs to its own page: neither carries the other
        // page's geometry.
        let page0Lines = HighlightService.lineRects(for: selection, on: page0)
        let union0 = page0Lines.dropFirst().reduce(page0Lines[0]) { $0.union($1) }
        XCTAssertEqual(annotation0.bounds.minY, union0.minY, accuracy: 0.5)
        XCTAssertEqual(annotation0.bounds.maxY, union0.maxY, accuracy: 0.5)
        XCTAssertLessThanOrEqual(annotation0.bounds.maxY, page0.bounds(for: .mediaBox).maxY)
        XCTAssertEqual(summary.quadCount, page0Lines.count + page1LineRects.count)
    }

    func testCrossPageHighlightSurvivesSaveAndReopen() throws {
        let url = try makeFixture(pageCount: 2, linesPerPage: 3)
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page0 = try XCTUnwrap(document.page(at: 0))
        let page1 = try XCTUnwrap(document.page(at: 1))
        let page0Length = (page0.string ?? "").count
        let page1Length = (page1.string ?? "").count

        let selection = try XCTUnwrap(
            document.selection(
                from: page0,
                atCharacterIndex: page0Length - 15,
                to: page1,
                atCharacterIndex: min(40, page1Length - 1)
            )
        )
        try HighlightService.addHighlight(from: selection, to: document)

        let saved = try XCTUnwrap(document.dataRepresentation())
        try saved.write(to: url, options: .atomic)

        let reopened = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(reopened.page(at: 0)?.annotations.count, 1)
        XCTAssertEqual(reopened.page(at: 1)?.annotations.count, 1)
        XCTAssertTrue(reopened.page(at: 0)?.annotations.first?.isHighlightMarkup ?? false)
        XCTAssertTrue(reopened.page(at: 1)?.annotations.first?.isHighlightMarkup ?? false)
        XCTAssertGreaterThan(reopened.page(at: 0)?.annotations.first?.quadrilateralPoints?.count ?? 0, 0)
        XCTAssertGreaterThan(reopened.page(at: 1)?.annotations.first?.quadrilateralPoints?.count ?? 0, 0)
    }

    // MARK: - Nothing to mark

    func testSelectionWithoutTextIsRejected() throws {
        let url = try makeFixture(pageCount: 1, linesPerPage: 1)
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))

        // A selection that covers no page at all has no text: the same shape as
        // dragging across a margin or an image.
        let empty = PDFSelection(document: document)

        XCTAssertThrowsError(try HighlightService.addHighlight(from: empty, to: document)) { error in
            XCTAssertEqual(error as? HighlightService.Failure, .noSelectableText)
        }
        XCTAssertTrue(page.annotations.isEmpty)
    }

    // MARK: - Coexistence

    func testExistingAnnotationsArePreserved() throws {
        let url = try makeFixture()
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))

        // Two annotations "from another app": a square and a sticky note.
        let square = PDFAnnotation(
            bounds: CGRect(x: 300, y: 600, width: 80, height: 40),
            forType: .square,
            withProperties: nil
        )
        square.color = .systemRed
        page.addAnnotation(square)

        let note = PDFAnnotation(
            bounds: CGRect(x: 400, y: 620, width: 24, height: 24),
            forType: .text,
            withProperties: nil
        )
        note.contents = "existing note"
        page.addAnnotation(note)

        let selection = try select(document, pageIndex: 0, from: 0, to: 15)
        try HighlightService.addHighlight(from: selection, to: document)

        let saved = try XCTUnwrap(document.dataRepresentation())
        try saved.write(to: url, options: .atomic)

        let reopened = try XCTUnwrap(PDFDocument(url: url))
        let annotations = try XCTUnwrap(reopened.page(at: 0)?.annotations)
        // A sticky note is written together with a popup annotation, so the
        // total is not the interesting number — what matters is that every
        // pre-existing annotation is still there, next to the new highlight.
        XCTAssertEqual(annotations.filter(\.isHighlightMarkup).count, 1)
        XCTAssertEqual(annotations.filter { $0.isType("Square") }.count, 1)
        XCTAssertEqual(annotations.filter { $0.isType("Text") }.count, 1)

        let reopenedSquare = try XCTUnwrap(
            annotations.first { $0.isType("Square") }
        )
        XCTAssertEqual(reopenedSquare.bounds.origin.x, 300, accuracy: 0.5)
        XCTAssertEqual(reopenedSquare.bounds.origin.y, 600, accuracy: 0.5)
        XCTAssertEqual(reopenedSquare.bounds.width, 80, accuracy: 0.5)

        let reopenedNote = try XCTUnwrap(
            annotations.first { $0.isType("Text") }
        )
        XCTAssertEqual(reopenedNote.contents, "existing note")
    }

    // MARK: - Rendering

    /// The written appearance must actually paint the selected lines, not the
    /// bounding box. This is the check that a `/QuadPoints` array alone cannot
    /// give: it renders the saved page the way another reader would.
    func testRenderedHighlightCoversTheSelectedLinesAndNotTheGap() throws {
        let url = try makeFixture(pageCount: 1, linesPerPage: 2)
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))

        let selection = try selectWholePage(document, pageIndex: 0)
        let rects = HighlightService.lineRects(for: selection, on: page)
        XCTAssertEqual(rects.count, 2)

        try HighlightService.addHighlight(from: selection, to: document)
        let saved = try XCTUnwrap(document.dataRepresentation())
        try saved.write(to: url, options: .atomic)

        let reopened = try XCTUnwrap(PDFDocument(url: url))
        let rendered = try XCTUnwrap(reopened.page(at: 0))
        let bitmap = try render(rendered)

        // Text glyphs cover part of every line, so the check is a ratio over the
        // line's rectangle rather than one pixel.
        XCTAssertGreaterThan(bitmap.yellowFraction(in: rects[0]), 0.3,
                             "the first selected line should be painted")
        XCTAssertGreaterThan(bitmap.yellowFraction(in: rects[1]), 0.3,
                             "the second selected line should be painted")

        // Inside the annotation's bounds but to the right of the short first
        // line: a rectangle-only highlight would paint this.
        let gap = CGRect(
            x: rects[0].maxX + 10,
            y: rects[0].minY,
            width: max(rects[1].maxX - rects[0].maxX - 20, 1),
            height: rects[0].height
        )
        XCTAssertLessThan(bitmap.yellowFraction(in: gap), 0.02,
                          "the space to the right of a short line must stay clear")
    }

    // MARK: - Rendering helpers

    private struct RenderedPage {
        let representation: NSBitmapImageRep
        let pageSize: CGSize

        /// The share of pixels inside `rect` (given in PDF page space) that are
        /// painted like a yellow highlight.
        func yellowFraction(in rect: CGRect) -> Double {
            // The thumbnail may be rendered at a different pixel density than
            // the page's point size, so convert through the actual ratio.
            let scaleX = CGFloat(representation.pixelsWide) / pageSize.width
            let scaleY = CGFloat(representation.pixelsHigh) / pageSize.height

            let minX = max(Int((rect.minX * scaleX).rounded()), 0)
            let maxX = min(Int((rect.maxX * scaleX).rounded()), representation.pixelsWide - 1)
            let minY = max(Int(((pageSize.height - rect.maxY) * scaleY).rounded()), 0)
            let maxY = min(Int(((pageSize.height - rect.minY) * scaleY).rounded()), representation.pixelsHigh - 1)
            guard minX <= maxX, minY <= maxY else { return 0 }

            var total = 0
            var yellow = 0
            for py in minY...maxY {
                for px in minX...maxX {
                    total += 1
                    if Self.isHighlightYellow(representation.colorAt(x: px, y: py)) {
                        yellow += 1
                    }
                }
            }
            return total == 0 ? 0 : Double(yellow) / Double(total)
        }

        private static func isHighlightYellow(_ color: NSColor?) -> Bool {
            guard let rgb = color?.usingColorSpace(.sRGB) else { return false }
            return rgb.redComponent > 0.75 && rgb.greenComponent > 0.55 && rgb.blueComponent < 0.6
        }
    }

    private func render(_ page: PDFPage) throws -> RenderedPage {
        let bounds = page.bounds(for: .mediaBox)
        let image = page.thumbnail(of: NSSize(width: bounds.width, height: bounds.height), for: .mediaBox)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let representation = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return RenderedPage(representation: representation, pageSize: bounds.size)
    }
}

extension PDFAnnotation {
    /// PDFKit reports `type` as "Highlight" while `PDFAnnotationSubtype.rawValue`
    /// is "/Highlight", depending on whether the annotation came from memory or
    /// from a file. Comparing the suffix accepts both.
    var isHighlightMarkup: Bool { isType("Highlight") }

    func isType(_ name: String) -> Bool {
        type?.hasSuffix(name) == true
    }
}

/// Reads annotation dictionaries straight out of the written PDF.
///
/// Asserting on the bytes is the only way to check what a *different* reader
/// will see: PDFKit's in-memory annotation can be right while the serialised
/// dictionary is not.
enum RawPDFInspector {

    static func quadPointArrays(in data: Data) -> [[Double]] {
        guard let text = String(data: data, encoding: .isoLatin1) else { return [] }
        var results: [[Double]] = []
        var cursor = text.startIndex

        while let marker = text.range(of: "/QuadPoints", range: cursor..<text.endIndex),
              let open = text.range(of: "[", range: marker.upperBound..<text.endIndex),
              let close = text.range(of: "]", range: open.upperBound..<text.endIndex) {
            let numbers = text[open.upperBound..<close.lowerBound]
                .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" })
                .compactMap { Double($0) }
            results.append(numbers)
            cursor = close.upperBound
        }
        return results
    }

    static func occurrences(of needle: String, in data: Data) -> Int {
        guard let text = String(data: data, encoding: .isoLatin1) else { return 0 }
        return text.components(separatedBy: needle).count - 1
    }
}
