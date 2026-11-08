import AppKit
import PDFKit
import XCTest
@testable import YoPDFCore

/// What the hover card says about one sticker.
///
/// A sticker can stand for a whole thread, so the interesting cases are the
/// ones the popover used to be needed for: several bodies, each with its own
/// paper colour, in thread order.
@MainActor
final class NoteHoverPreviewTests: XCTestCase {

    /// `tearDown()` is nonisolated in XCTest, so the cleanup list cannot be
    /// main-actor isolated. Tests run serially; nothing else touches it.
    nonisolated(unsafe) private var temporaryFiles: [URL] = []

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
            let directory = url.deletingLastPathComponent()
            if directory.lastPathComponent.hasPrefix("YoPDFTests-") {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        temporaryFiles.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeModel() -> PDFDocumentModel {
        PDFDocumentModel(access: SecurityScopeSpy())
    }

    private func makeFixture(named name: String) throws -> URL {
        let data = try PDFFixtureFactory.makeParagraphData(pageCount: 1, linesPerPage: 3)
        let document = try XCTUnwrap(PDFDocument(data: data))
        return try write(document, named: name)
    }

    private func write(_ document: PDFDocument, named name: String) throws -> URL {
        let data = try XCTUnwrap(document.dataRepresentation(), "the fixture must serialize")
        let url = try PDFFixtureFactory.writeTemporaryFile(named: "\(name).pdf", contents: data)
        temporaryFiles.append(url)
        return url
    }

    private func openModel(at url: URL) -> PDFDocumentModel {
        let model = makeModel()
        XCTAssertTrue(model.open(url: url), "the fixture must open")
        return model
    }

    @discardableResult
    private func addPageNote(
        to model: PDFDocumentModel,
        contents: String,
        style: NoteStickerStyle
    ) throws -> NoteSelection {
        let page = try XCTUnwrap(model.document?.page(at: 0))
        let draft = try XCTUnwrap(model.pageNoteDraft(at: CGPoint(x: 300, y: 400), on: page))
        switch model.addNote(draft, contents: contents, style: style) {
        case let .success(note):
            return note
        case let .failure(error):
            throw error
        }
    }

    private func appendThought(
        to selection: NoteSelection,
        in model: PDFDocumentModel,
        contents: String,
        style: NoteStickerStyle
    ) throws -> NoteSelection {
        switch model.addThought(to: selection, contents: contents, style: style) {
        case let .success(note):
            return note
        case let .failure(error):
            throw error
        }
    }

    private func onlyMarker(in model: PDFDocumentModel) throws -> NoteMarker {
        XCTAssertEqual(model.noteMarkers.count, 1, "the fixture holds exactly one sticker")
        return try XCTUnwrap(model.noteMarkers.first)
    }

    private func handBuiltMarker(
        contents: [String],
        styles: [NoteStickerStyle],
        stickerStyle: NoteStickerStyle
    ) -> NoteMarker {
        precondition(contents.count == styles.count, "one style per body")
        let annotations = contents.map { body -> PDFAnnotation in
            let annotation = PDFAnnotation(
                bounds: CGRect(x: 300, y: 400, width: 24, height: 24),
                forType: .text,
                withProperties: nil
            )
            annotation.contents = body
            return annotation
        }
        let entries = (0..<contents.count).map { index in
            NoteThreadEntry(
                annotation: annotations[index],
                contents: contents[index],
                style: styles[index]
            )
        }
        return NoteMarker(
            annotation: annotations[0],
            pageIndex: 0,
            center: CGPoint(x: 312, y: 412),
            bounds: CGRect(x: 293, y: 398, width: 38, height: 32),
            maskBounds: CGRect(x: 291, y: 396, width: 42, height: 36),
            style: stickerStyle,
            count: entries.count,
            showsCountBadge: entries.count > 1,
            threadContents: contents,
            threadEntries: entries,
            sourceHitBounds: [CGRect(x: 300, y: 400, width: 24, height: 24)]
        )
    }

    // MARK: - Single note

    func testReadsTheStickerBodyWithoutOpeningIt() throws {
        let url = try makeFixture(named: "hover-single")
        let model = openModel(at: url)
        let style = NoteStickerStyle(motif: .cat, palette: .mint)
        try addPageNote(to: model, contents: "Remember this paragraph", style: style)

        let preview = NoteHoverPreview(marker: try onlyMarker(in: model))

        XCTAssertEqual(preview.entries.map(\.contents), ["Remember this paragraph"])
        XCTAssertEqual(preview.entries.map(\.palette), [.mint])
        XCTAssertEqual(preview.entries.map(\.motif), [.cat])
        XCTAssertEqual(preview.palette, .mint, "the card is tinted with the sticker's paper")
        XCTAssertEqual(preview.motif, .cat)
        XCTAssertNil(preview.countTitle, "one note is not a thread")
        XCTAssertEqual(preview.title, NoteHoverPreview.untitled)
    }

    func testKeepsACustomStickerTitle() throws {
        let url = try makeFixture(named: "hover-titled")
        let model = openModel(at: url)
        let style = NoteStickerStyle(motif: .star, palette: .sand, title: "Reading list")
        try addPageNote(to: model, contents: "Chapter 4", style: style)

        let preview = NoteHoverPreview(marker: try onlyMarker(in: model))

        XCTAssertEqual(preview.title, "Reading list")
    }

    func testDoesNotGrowACountForOneNote() throws {
        let url = try makeFixture(named: "hover-one")
        let model = openModel(at: url)
        try addPageNote(to: model, contents: "Alone", style: .newNote)

        let preview = NoteHoverPreview(marker: try onlyMarker(in: model))

        XCTAssertEqual(preview.entries.count, 1)
        XCTAssertNil(preview.countTitle)
    }

    // MARK: - Threads

    func testListsEveryNoteInAThreadInOrder() throws {
        let url = try makeFixture(named: "hover-thread")
        let model = openModel(at: url)

        let first = try addPageNote(
            to: model,
            contents: "First thought",
            style: NoteStickerStyle(motif: .cat, palette: .honey)
        )
        let second = try appendThought(
            to: first,
            in: model,
            contents: "Second thought",
            style: NoteStickerStyle(motif: .shiba, palette: .mint)
        )
        try appendThought(
            to: second,
            in: model,
            contents: "Third thought",
            style: NoteStickerStyle(motif: .panda, palette: .sky)
        )

        let marker = try onlyMarker(in: model)
        XCTAssertEqual(marker.count, 3, "the fixture must really be one sticker with three notes")

        let preview = NoteHoverPreview(marker: marker)

        XCTAssertEqual(
            preview.entries.map(\.contents),
            ["First thought", "Second thought", "Third thought"],
            "a thread is shown in its stored order, not as one joined paragraph"
        )
        XCTAssertEqual(preview.entries.map(\.palette), [.honey, .mint, .sky])
        XCTAssertEqual(preview.entries.map(\.motif), [.cat, .shiba, .panda])
        XCTAssertEqual(preview.countTitle, "3 notes")
        XCTAssertEqual(preview.palette, .honey, "the card takes the sticker's own paper")
    }

    func testShowsABlankNoteInsteadOfDroppingIt() {
        let stickerStyle = NoteStickerStyle(motif: .plain, palette: .sand)
        let marker = handBuiltMarker(
            contents: ["   ", "Second"],
            styles: [stickerStyle, NoteStickerStyle(motif: .bow, palette: .rose)],
            stickerStyle: stickerStyle
        )

        let preview = NoteHoverPreview(marker: marker)

        XCTAssertEqual(preview.entries.count, 2)
        XCTAssertTrue(preview.entries[0].isBlank, "the card can still say the note exists")
        XCTAssertFalse(preview.entries[1].isBlank)
        XCTAssertEqual(preview.countTitle, "2 notes")
        XCTAssertEqual(preview.entries[1].palette, .rose)
    }

    func testFallsBackToTheBodyListWhenEntriesAreMissing() {
        let style = NoteStickerStyle(motif: .plain, palette: .honey)
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 300, y: 400, width: 24, height: 24),
            forType: .text,
            withProperties: nil
        )
        annotation.contents = "Solo body"
        let marker = NoteMarker(
            annotation: annotation,
            pageIndex: 0,
            center: CGPoint(x: 312, y: 412),
            bounds: CGRect(x: 293, y: 398, width: 38, height: 32),
            maskBounds: CGRect(x: 291, y: 396, width: 42, height: 36),
            style: style
        )

        let preview = NoteHoverPreview(marker: marker)

        XCTAssertEqual(preview.entries.map(\.contents), ["Solo body"])
        XCTAssertNil(preview.countTitle)
    }
}
