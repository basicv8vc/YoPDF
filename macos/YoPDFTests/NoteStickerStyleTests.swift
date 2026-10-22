import AppKit
import PDFKit
import XCTest
@testable import YoPDFCore

/// Sticker style, marker anchors, permissions and draft protection, against
/// real PDFs and PDFKit.
///
/// The style is document data, so every claim here is checked by serializing
/// and reopening a file, not by inspecting an in-memory dictionary.
@MainActor
final class NoteStickerStyleTests: XCTestCase {

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

    private func write(_ document: PDFDocument, named name: String) throws -> URL {
        let data = try XCTUnwrap(document.dataRepresentation(), "the fixture must serialize")
        let url = try PDFFixtureFactory.writeTemporaryFile(named: "\(name).pdf", contents: data)
        temporaryFiles.append(url)
        return url
    }

    private func makeFixture(
        pageCount: Int = 2,
        cropBox: CGRect? = nil,
        rotation: Int? = nil,
        named name: String = "sticker"
    ) throws -> URL {
        let data = try PDFFixtureFactory.makeParagraphData(pageCount: pageCount, linesPerPage: 4)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        if let cropBox {
            page.setBounds(cropBox, for: .cropBox)
        }
        if let rotation {
            page.rotation = rotation
        }
        return try write(document, named: name)
    }

    private func openModel(at url: URL) -> PDFDocumentModel {
        let model = makeModel()
        XCTAssertTrue(model.open(url: url), "the fixture must open")
        return model
    }

    @discardableResult
    private func addPageNote(
        to model: PDFDocumentModel,
        pageIndex: Int = 0,
        point: CGPoint = CGPoint(x: 300, y: 400),
        contents: String = "Sticker body",
        style: NoteStickerStyle = .plain
    ) throws -> NoteSelection {
        let page = try XCTUnwrap(model.document?.page(at: pageIndex))
        let draft = try XCTUnwrap(model.pageNoteDraft(at: point, on: page))
        switch model.addNote(draft, contents: contents, style: style) {
        case let .success(note):
            return note
        case let .failure(error):
            XCTFail("note creation failed: \(error)")
            throw error
        }
    }

    private func textNote(on pageIndex: Int, in document: PDFDocument) throws -> PDFAnnotation {
        let page = try XCTUnwrap(document.page(at: pageIndex))
        return try XCTUnwrap(
            page.annotations.first { NoteService.isTextAnnotation($0) },
            "the page must hold a standard /Text note"
        )
    }

    /// Writes a PDF with one hand-built note, for cases that need exact key
    /// contents that the model would never produce.
    private func makeHandBuiltNoteFixture(
        bounds: CGRect = CGRect(x: 300, y: 400, width: 22, height: 22),
        contents: String = "Hand-built body",
        paper: NotePaperColor? = nil,
        style: String? = nil,
        vendorMetadata: String? = nil,
        anchor: CGPoint? = nil,
        cropBox: CGRect? = nil,
        rotation: Int? = nil,
        named name: String = "hand-built"
    ) throws -> URL {
        let data = try PDFFixtureFactory.makeParagraphData(pageCount: 1, linesPerPage: 2)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        if let cropBox { page.setBounds(cropBox, for: .cropBox) }
        if let rotation { page.rotation = rotation }

        let note = PDFAnnotation(bounds: bounds, forType: .text, withProperties: nil)
        note.iconType = .comment
        note.contents = contents
        if let paper {
            note.color = paper.color
            note.setValue(paper.rawValue, forAnnotationKey: NoteService.paperColorKey)
        }
        if let style {
            note.setValue(style, forAnnotationKey: NoteService.styleKey)
        }
        if let vendorMetadata {
            note.setValue(vendorMetadata, forAnnotationKey: PDFAnnotationKey(rawValue: "/VendorData"))
        }
        if let anchor {
            NoteService.setAnchor(anchor, on: note, page: page)
        }
        page.addAnnotation(note)
        return try write(document, named: name)
    }

    private func marker(on pageIndex: Int = 0, in model: PDFDocumentModel) throws -> NoteMarker {
        try XCTUnwrap(model.noteMarkers.first { $0.pageIndex == pageIndex })
    }

    private func selection(
        in document: PDFDocument,
        pageIndex: Int,
        from start: Int
    ) throws -> PDFSelection {
        let page = try XCTUnwrap(document.page(at: pageIndex))
        let length = (page.string ?? "").count
        let lower = min(max(start, 0), max(length - 1, 0))
        let upper = min(lower + 24, length)
        return try XCTUnwrap(
            document.selection(from: page, atCharacterIndex: lower, to: page, atCharacterIndex: upper)
        )
    }

    // MARK: - Inventory and palette

    func testMotifInventoryMatchesTheTwentyRuntimeAssets() {
        XCTAssertEqual(NoteMotif.allCases.count, 21)
        XCTAssertEqual(Set(NoteMotif.allCases.map(\.rawValue)).count, 21)

        let expected: [NoteMotif] = [
            .bunny, .cat, .flower, .star,
            .tuxedoCat, .sleepyCat, .shiba, .puppy,
            .hamster, .panda, .redPanda, .otter,
            .heart, .cloud, .cherry, .bow,
            .roseStamp, .botanical, .letter, .washi,
        ]
        XCTAssertEqual(Array(NoteMotif.allCases.prefix(20)), expected)
        XCTAssertNil(NoteMotif.plain.assetName)

        let names = NoteMotif.allCases.compactMap(\.assetName)
        XCTAssertEqual(names.count, 20)
        XCTAssertEqual(Set(names).count, 20, "asset names must be unique")
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("PDFSticker") })

        XCTAssertEqual(NoteStickerCollection.cream.motifs.count, 4)
        XCTAssertEqual(NoteStickerCollection.pets.motifs.count, 4)
        XCTAssertEqual(NoteStickerCollection.animals.motifs.count, 4)
        XCTAssertEqual(NoteStickerCollection.doodle.motifs.count, 4)
        XCTAssertEqual(NoteStickerCollection.vintage.motifs.count, 4)
        XCTAssertEqual(NoteStickerCollection.minimal.motifs, [.plain])
        XCTAssertEqual(
            Set(NoteStickerCollection.allCases.flatMap(\.motifs)),
            Set(NoteMotif.allCases)
        )
    }

    func testPaletteValuesAreTheExistingNotePaperColors() {
        XCTAssertEqual(NotePaperColor.allCases.count, 6)
        let expected: [NotePaperColor: String] = [
            .honey: "FFEDA6",
            .rose: "FFD9D9",
            .mint: "CCEDD4",
            .sky: "CFE6FA",
            .lavender: "E3D9F7",
            .sand: "F0E6D1",
        ]
        for color in NotePaperColor.allCases {
            XCTAssertEqual(color.hex, expected[color], "\(color.rawValue) must not drift")
        }
    }

    // MARK: - New note default

    /// ShuaMac's default style stores no motif and resolves it to the bunny, so a
    /// new note must open as Little Bunny rather than as a blank square.
    func testNewNoteDefaultIsShuaMacsDefaultSticker() {
        XCTAssertEqual(NoteStickerStyle.newNote, NoteStickerStyle(motif: .bunny, palette: .honey))
        XCTAssertEqual(NoteStickerStyle.newNote.motif.collection, .cream)
        XCTAssertEqual(NoteStickerStyle.newNote.title, "")
        XCTAssertEqual(NoteStickerStyle.newNote.symbol, NoteStickerStyle.defaultSymbol)
    }

    /// The default has to be written, not implied: a reader that has no fallback
    /// rule of its own must still see the bunny.
    func testNewNoteDefaultIsPersistedAsAnExplicitMotif() throws {
        let url = try makeFixture()
        let model = openModel(at: url)
        try addPageNote(to: model, contents: "Default sticker", style: .newNote)

        XCTAssertEqual(model.noteMarkers.first?.style, .newNote)
        XCTAssertEqual(model.save(), .saved)

        let reopened = try XCTUnwrap(PDFDocument(url: url))
        let note = try textNote(on: 0, in: reopened)
        XCTAssertEqual(NoteService.style(of: note), NoteStickerStyle(motif: .bunny, palette: .honey))
        XCTAssertEqual(
            note.value(forAnnotationKey: NoteService.styleKey) as? String,
            "{\"v\":2,\"title\":\"\",\"symbol\":\"note.text\",\"motif\":\"bunny\",\"palette\":\"honey\"}"
        )
    }

    /// The paper-only compatibility path supplies a tint, not an appearance, so
    /// it must not resurrect Simple Paper as the create default.
    func testPaperOnlyComposerCreateKeepsTheNewNoteMotif() throws {
        let url = try makeFixture()
        let model = openModel(at: url)
        let page = try XCTUnwrap(model.document?.page(at: 0))
        let draft = try XCTUnwrap(model.pageNoteDraft(at: CGPoint(x: 300, y: 400), on: page))
        let store = NoteComposerStore()

        XCTAssertTrue(store.begin(
            mode: .create(draft),
            anchorRect: .zero,
            pageLabel: draft.pageLabel,
            excerpt: draft.excerpt,
            contents: "",
            paper: .sky
        ))
        XCTAssertEqual(store.session?.style, NoteStickerStyle(motif: .bunny, palette: .sky))
        XCTAssertEqual(store.session?.initialPaper, .sky)
    }

    /// A note with no style key keeps the PR #6 appearance. Reading a document
    /// must never restyle what an older build wrote.
    func testMissingStyleKeyStillReadsAsSimplePaper() throws {
        let url = try makeHandBuiltNoteFixture(paper: .rose)
        let model = openModel(at: url)
        let note = try textNote(on: 0, in: model.document ?? PDFDocument())

        XCTAssertEqual(NoteService.style(of: note), NoteStickerStyle(motif: .plain, palette: .rose))
        XCTAssertNotEqual(NoteService.style(of: note).motif, NoteStickerStyle.newNote.motif)
    }

    // MARK: - Style serialization

    func testStyleRoundTripsThroughPDFKitSerialization() throws {
        let url = try makeFixture()
        let model = openModel(at: url)
        let style = NoteStickerStyle(motif: .tuxedoCat, palette: .lavender)
        try addPageNote(to: model, contents: "Round trip sticker", style: style)

        XCTAssertEqual(model.save(), .saved)
        let reopened = try XCTUnwrap(PDFDocument(url: url))
        let note = try textNote(on: 0, in: reopened)

        XCTAssertEqual(NoteService.style(of: note), style)
        XCTAssertEqual(NoteService.paperColor(of: note), .lavender)
        XCTAssertEqual(MarkupColorPalette.hex(from: note.color), NotePaperColor.lavender.hex)
        XCTAssertEqual(note.contents, "Round trip sticker")
        XCTAssertNotNil(note.value(forAnnotationKey: NoteService.styleKey))
        XCTAssertEqual(
            note.value(forAnnotationKey: NoteService.paperColorKey) as? String,
            "lavender"
        )
    }

    func testStyleValueHasTheDocumentedVersionedShape() {
        let style = NoteStickerStyle(motif: .bunny, palette: .honey)
        XCTAssertEqual(
            style.serialized,
            "{\"v\":2,\"title\":\"\",\"symbol\":\"note.text\",\"motif\":\"bunny\",\"palette\":\"honey\"}"
        )
        XCTAssertEqual(
            NoteStickerStyle(serialized: style.serialized)?.serialized,
            style.serialized
        )
    }

    func testVersionOneStyleStillReadsWithEmptyTitleAndDefaultSymbol() {
        let style = NoteStickerStyle(
            serialized: "{\"v\":1,\"motif\":\"washi\",\"palette\":\"rose\"}"
        )
        XCTAssertEqual(style?.motif, .washi)
        XCTAssertEqual(style?.palette, .rose)
        XCTAssertEqual(style?.title, "")
        XCTAssertEqual(style?.symbol, NoteStickerStyle.defaultSymbol)
        XCTAssertEqual(
            style?.serialized,
            "{\"v\":2,\"title\":\"\",\"symbol\":\"note.text\",\"motif\":\"washi\",\"palette\":\"rose\"}"
        )
    }

    func testTitleAndSymbolRoundTripThroughPDFKitSerialization() throws {
        let url = try makeFixture()
        let model = openModel(at: url)
        let style = NoteStickerStyle(
            motif: .flower,
            palette: .mint,
            title: "Connection",
            symbol: "link"
        )
        try addPageNote(to: model, contents: "Templated note", style: style)
        XCTAssertEqual(model.save(), .saved)

        let reopened = try XCTUnwrap(PDFDocument(url: url))
        let note = try textNote(on: 0, in: reopened)
        XCTAssertEqual(NoteService.style(of: note), style)
        XCTAssertEqual(note.contents, "Templated note")
    }

    func testMalformedTitleAndSymbolDegradeWithoutLosingTheStyle() {
        let style = NoteStickerStyle(
            serialized: "{\"v\":2,\"title\":42,\"symbol\":\"   \",\"motif\":\"cat\",\"palette\":\"sky\"}"
        )
        XCTAssertEqual(style?.title, "")
        XCTAssertEqual(style?.symbol, NoteStickerStyle.defaultSymbol)
        XCTAssertEqual(style?.motif, .cat)
        XCTAssertEqual(style?.palette, .sky)
    }

    func testStyleSerializationEscapesQuotesAndNewlines() {
        let title = "He said \"look\"\nsecond line"
        let style = NoteStickerStyle(motif: .plain, palette: .sand, title: title, symbol: "quote.opening")
        XCTAssertEqual(NoteStickerStyle(serialized: style.serialized)?.title, title)
        XCTAssertEqual(NoteStickerStyle(serialized: style.serialized)?.symbol, "quote.opening")
    }

    func testAppearanceOnlyDropsTemplateIdentity() {
        let template = NoteStickerStyle(
            motif: .cat,
            palette: .lavender,
            title: "Review",
            symbol: "text.badge.checkmark"
        )
        XCTAssertEqual(
            template.appearanceOnly,
            NoteStickerStyle(motif: .cat, palette: .lavender)
        )
    }

    func testMarkerUsesTheShuaArtworkFaceAndThreePointHitInset() throws {
        let model = openModel(at: try makeFixture())
        let added = try addPageNote(
            to: model,
            point: CGPoint(x: 300, y: 400),
            style: NoteStickerStyle(motif: .cherry, palette: .rose)
        )
        let page = try XCTUnwrap(model.document?.page(at: 0))
        let marker = try marker(in: model)

        XCTAssertEqual(marker.bounds.width, 32, accuracy: 0.01)
        XCTAssertEqual(marker.bounds.height, 32, accuracy: 0.01)
        XCTAssertEqual(NoteService.markerDisplaySize, 32)
        XCTAssertEqual(NoteService.hitRect(for: added.annotation, on: page).width, 38, accuracy: 0.01)

        let center = CGPoint(x: marker.bounds.midX, y: marker.bounds.midY)
        XCTAssertNotNil(model.noteSelection(at: CGPoint(x: center.x + 18, y: center.y), on: page))
        XCTAssertNil(model.noteSelection(at: CGPoint(x: center.x + 21, y: center.y), on: page))
    }

    func testTitleOrSymbolChangeIsAnUndoableDraftAndDocumentEdit() throws {
        let url = try makeFixture()
        let model = openModel(at: url)
        let added = try addPageNote(
            to: model,
            contents: "Body",
            style: NoteStickerStyle(motif: .star, palette: .honey)
        )
        let store = NoteComposerStore()
        XCTAssertTrue(store.begin(
            mode: .edit(added),
            anchorRect: .zero,
            pageLabel: added.pageLabel,
            excerpt: added.excerpt,
            contents: added.contents,
            style: added.style
        ))
        let session = try XCTUnwrap(store.session)
        let revision = store.revision
        session.style.title = "Insight"
        session.style.symbol = "lightbulb"
        XCTAssertTrue(session.hasUncommittedChanges)
        XCTAssertGreaterThan(store.revision, revision)

        guard case .success = store.commit(using: model) else {
            return XCTFail("the template identity must be savable")
        }
        let saved = try textNote(on: 0, in: try XCTUnwrap(model.document))
        XCTAssertEqual(NoteService.style(of: saved).title, "Insight")
        XCTAssertEqual(NoteService.style(of: saved).symbol, "lightbulb")

        XCTAssertTrue(model.undoMarkup())
        let restored = try textNote(on: 0, in: try XCTUnwrap(model.document))
        XCTAssertEqual(NoteService.style(of: restored).title, "")
        XCTAssertEqual(NoteService.style(of: restored).symbol, NoteStickerStyle.defaultSymbol)
    }

    func testTemplateSeedResetsWhenTheComposerTextBecomesEmpty() throws {
        let model = openModel(at: try makeFixture())
        let store = NoteComposerStore()
        let page = try XCTUnwrap(model.document?.page(at: 0))
        let draft = try XCTUnwrap(model.pageNoteDraft(at: CGPoint(x: 300, y: 400), on: page))
        XCTAssertTrue(store.begin(
            mode: .create(draft),
            anchorRect: .zero,
            pageLabel: draft.pageLabel,
            excerpt: nil,
            contents: "Key insight:\n\nWhy it matters:\n",
            style: .plain
        ))
        let session = try XCTUnwrap(store.session)
        var selection = NoteTemplateSelection()
        selection.restoreIfNeeded(text: session.contents, templates: NoteTemplate.builtIns())
        session.templateSelection = selection
        XCTAssertNotNil(session.templateSelection.seed)

        session.contents = ""
        XCTAssertNil(session.templateSelection.seed)
    }

    func testMissingStyleFallsBackToTheLegacyPaperAndReadsTheBody() throws {
        let url = try makeHandBuiltNoteFixture(contents: "PR #6 body", paper: .sky)
        let model = openModel(at: url)
        let note = try textNote(on: 0, in: model.document ?? PDFDocument())

        XCTAssertEqual(NoteService.style(of: note), NoteStickerStyle(motif: .plain, palette: .sky))
        XCTAssertEqual(model.noteMarkers.count, 1)
        XCTAssertEqual(model.noteMarkers.first?.style, NoteStickerStyle(motif: .plain, palette: .sky))
        XCTAssertEqual(model.noteMarkers.first?.paperColor, .sky)
    }

    func testMalformedStyleStillOpensAndDegradesToLegacyPaper() throws {
        let url = try makeHandBuiltNoteFixture(
            contents: "Malformed style body",
            paper: .mint,
            style: "{not json"
        )
        let model = openModel(at: url)
        let note = try textNote(on: 0, in: model.document ?? PDFDocument())

        XCTAssertEqual(model.document?.pageCount, 1, "a corrupt style key must not hide the document")
        XCTAssertEqual(note.contents, "Malformed style body")
        XCTAssertEqual(NoteService.style(of: note), NoteStickerStyle(motif: .plain, palette: .mint))

        XCTAssertEqual(model.save(), .saved)
        let reopened = try XCTUnwrap(PDFDocument(url: url))
        let reopenedNote = try textNote(on: 0, in: reopened)
        XCTAssertEqual(reopenedNote.contents, "Malformed style body")
        XCTAssertEqual(NoteService.style(of: reopenedNote), NoteStickerStyle(motif: .plain, palette: .mint))
    }

    func testUnknownMotifDegradesToPlainAndKeepsThePalette() {
        let style = NoteStickerStyle(
            serialized: "{\"v\":1,\"motif\":\"grumpyCat\",\"palette\":\"rose\"}"
        )
        XCTAssertEqual(style?.motif, NoteMotif.plain)
        XCTAssertEqual(style?.palette, NotePaperColor.rose)
    }

    func testUnknownPaletteFallsBackToTheLegacyPaper() throws {
        let url = try makeHandBuiltNoteFixture(
            paper: .sand,
            style: "{\"v\":1,\"motif\":\"washi\",\"palette\":\"chartreuse\"}"
        )
        let model = openModel(at: url)
        let note = try textNote(on: 0, in: model.document ?? PDFDocument())
        XCTAssertEqual(NoteService.style(of: note), NoteStickerStyle(motif: .washi, palette: .sand))
    }

    func testPR6NoteCanBeRestyledWithoutLosingItsBody() throws {
        let url = try makeHandBuiltNoteFixture(contents: "Legacy editable", paper: .sky)
        let model = openModel(at: url)
        let note = try textNote(on: 0, in: model.document ?? PDFDocument())
        XCTAssertNil(note.value(forAnnotationKey: NoteService.styleKey), "the fixture starts as PR #6")

        let selection = try XCTUnwrap(model.noteSelection(
            at: CGPoint(x: note.bounds.midX, y: note.bounds.midY),
            on: try XCTUnwrap(model.document?.page(at: 0))
        ))
        guard case let .success(updated) = model.updateNote(
            selection,
            contents: "Legacy editable",
            style: NoteStickerStyle(motif: .washi, palette: .sky)
        ) else {
            return XCTFail("a PR #6 note must be restyled")
        }
        XCTAssertEqual(updated.style, NoteStickerStyle(motif: .washi, palette: .sky))
        XCTAssertEqual(updated.contents, "Legacy editable")

        XCTAssertEqual(model.save(), .saved)
        let reopened = try XCTUnwrap(PDFDocument(url: url))
        let reopenedNote = try textNote(on: 0, in: reopened)
        XCTAssertEqual(reopenedNote.contents, "Legacy editable")
        XCTAssertEqual(NoteService.style(of: reopenedNote), NoteStickerStyle(motif: .washi, palette: .sky))
    }

    // MARK: - Third-party metadata

    func testThirdPartyMetadataIsPreservedWhenExplicitStyleAdoptsIt() throws {
        let url = try makeHandBuiltNoteFixture(
            contents: "Vendor note",
            paper: nil,
            vendorMetadata: "keep-me"
        )
        let model = openModel(at: url)
        let page = try XCTUnwrap(model.document?.page(at: 0))
        let note = try textNote(on: 0, in: try XCTUnwrap(model.document))
        XCTAssertFalse(NoteService.isYoPDFNote(note))
        XCTAssertTrue(model.noteMarkers.isEmpty)

        let selection = try XCTUnwrap(model.noteSelection(
            at: CGPoint(x: note.bounds.midX, y: note.bounds.midY),
            on: page
        ))
        XCTAssertEqual(selection.bounds, note.bounds, "the native icon is the hit target")

        guard case let .success(adopted) = model.updateNote(
            selection,
            contents: "Vendor note edited",
            style: NoteStickerStyle(motif: .cherry, palette: .honey)
        ) else {
            return XCTFail("a standard third-party note must be editable")
        }
        XCTAssertTrue(adopted.isYoPDFNote, "an explicit style change adopts the note")
        XCTAssertEqual(model.noteMarkers.count, 1)
        XCTAssertEqual(model.save(), .saved)

        let reopened = try XCTUnwrap(PDFDocument(url: url))
        let reopenedNote = try textNote(on: 0, in: reopened)
        XCTAssertEqual(
            reopenedNote.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/VendorData")) as? String,
            "keep-me",
            "unrelated metadata must survive"
        )
        XCTAssertNil(
            reopenedNote.value(forAnnotationKey: NoteService.anchorXKey),
            "an existing note must not be silently migrated to an anchor"
        )
        XCTAssertEqual(
            reopenedNote.value(forAnnotationKey: NoteService.identityKey) as? String,
            NoteService.identityValue
        )
        XCTAssertEqual(reopenedNote.contents, "Vendor note edited")
        XCTAssertEqual(NoteService.style(of: reopenedNote), NoteStickerStyle(motif: .cherry, palette: .honey))
    }

    func testNewNoteIdentityMarkerSurvivesSaveAndReopen() throws {
        let url = try makeFixture()
        let model = openModel(at: url)
        try addPageNote(
            to: model,
            contents: "Owned note",
            style: NoteStickerStyle(motif: .cat, palette: .sky)
        )
        let note = try textNote(on: 0, in: try XCTUnwrap(model.document))
        XCTAssertTrue(NoteService.isYoPDFNote(note))
        XCTAssertEqual(
            note.value(forAnnotationKey: NoteService.identityKey) as? String,
            NoteService.identityValue
        )
        XCTAssertEqual(model.noteMarkers.count, 1)

        XCTAssertEqual(model.save(), .saved)
        let reopened = try XCTUnwrap(PDFDocument(url: url))
        let reopenedNote = try textNote(on: 0, in: reopened)
        XCTAssertTrue(NoteService.isYoPDFNote(reopenedNote))
        XCTAssertEqual(
            reopenedNote.value(forAnnotationKey: NoteService.identityKey) as? String,
            NoteService.identityValue
        )
    }

    func testPR6NoteIsRecognizedWithoutBeingRewrittenOnOpen() throws {
        let url = try makeHandBuiltNoteFixture(contents: "PR #6 note", paper: .mint)
        let model = openModel(at: url)
        let note = try textNote(on: 0, in: try XCTUnwrap(model.document))

        XCTAssertTrue(NoteService.isYoPDFNote(note), "PR #6 paper/page-level keys identify the note")
        XCTAssertNil(note.value(forAnnotationKey: NoteService.identityKey))
        XCTAssertEqual(model.noteMarkers.count, 1, "a PR #6 note keeps its custom marker")

        XCTAssertEqual(model.save(), .saved)
        let reopened = try XCTUnwrap(PDFDocument(url: url))
        let reopenedNote = try textNote(on: 0, in: reopened)
        XCTAssertNil(
            reopenedNote.value(forAnnotationKey: NoteService.identityKey),
            "opening must not migrate the note"
        )
        XCTAssertTrue(NoteService.isYoPDFNote(reopenedNote))
    }

    func testUntouchedThirdPartyNoteKeepsNativeIconAndNativeHitTarget() throws {
        let bounds = CGRect(x: 300, y: 400, width: 24, height: 24)
        let url = try makeHandBuiltNoteFixture(
            bounds: bounds,
            contents: "Vendor note",
            vendorMetadata: "keep-me"
        )
        let model = openModel(at: url)
        let page = try XCTUnwrap(model.document?.page(at: 0))
        let note = try textNote(on: 0, in: try XCTUnwrap(model.document))

        XCTAssertFalse(NoteService.isYoPDFNote(note))
        XCTAssertTrue(model.noteMarkers.isEmpty, "no custom sticker overlay for a third-party note")

        let center = CGPoint(x: note.bounds.midX, y: note.bounds.midY)
        let selection = try XCTUnwrap(model.noteSelection(at: center, on: page))
        XCTAssertFalse(selection.isYoPDFNote)
        XCTAssertEqual(selection.bounds, note.bounds)
        XCTAssertNotNil(
            model.noteSelection(at: CGPoint(x: center.x + 10, y: center.y), on: page),
            "a point inside the native bounds must still open the note"
        )
        XCTAssertNil(
            model.noteSelection(at: CGPoint(x: center.x + 18, y: center.y), on: page),
            "the invisible 44×44 YoPDF card must not extend the hit target"
        )
    }

    func testExplicitRestyleAdoptsThirdPartyAndUndoRestoresNativePresentation() throws {
        let url = try makeHandBuiltNoteFixture(
            bounds: CGRect(x: 300, y: 400, width: 24, height: 24),
            contents: "Vendor note"
        )
        let model = openModel(at: url)
        let page = try XCTUnwrap(model.document?.page(at: 0))
        let note = try textNote(on: 0, in: try XCTUnwrap(model.document))
        let originalColor = NSColor(srgbRed: 0.9, green: 0.2, blue: 0.1, alpha: 1)
        note.color = originalColor

        let selection = try XCTUnwrap(model.noteSelection(
            at: CGPoint(x: note.bounds.midX, y: note.bounds.midY),
            on: page
        ))
        XCTAssertFalse(selection.isYoPDFNote)

        guard case let .success(adopted) = model.updateNote(
            selection,
            contents: "Vendor note",
            style: NoteStickerStyle(motif: .bunny, palette: .rose)
        ) else {
            return XCTFail("the explicit style change must succeed")
        }
        XCTAssertTrue(adopted.isYoPDFNote)
        XCTAssertEqual(adopted.bounds.width, NoteService.markerDisplaySize, accuracy: 0.01)
        XCTAssertEqual(model.noteMarkers.count, 1)
        XCTAssertEqual(
            note.value(forAnnotationKey: NoteService.identityKey) as? String,
            NoteService.identityValue
        )

        XCTAssertTrue(model.undoMarkup())
        let restored = try textNote(on: 0, in: try XCTUnwrap(model.document))
        XCTAssertFalse(NoteService.isYoPDFNote(restored), "Undo returns the note to third-party ownership")
        XCTAssertNil(restored.value(forAnnotationKey: NoteService.identityKey))
        XCTAssertNil(restored.value(forAnnotationKey: NoteService.styleKey))
        XCTAssertNil(restored.value(forAnnotationKey: NoteService.paperColorKey))
        XCTAssertTrue(restored.color.isEqual(originalColor), "the original /C colour is restored")
        XCTAssertTrue(model.noteMarkers.isEmpty)
        let center = CGPoint(x: restored.bounds.midX, y: restored.bounds.midY)
        XCTAssertNil(
            model.noteSelection(at: CGPoint(x: center.x + 18, y: center.y), on: page),
            "the native hit target is back after Undo"
        )

        XCTAssertTrue(model.redoMarkup())
        let redone = try textNote(on: 0, in: try XCTUnwrap(model.document))
        XCTAssertTrue(NoteService.isYoPDFNote(redone))
        XCTAssertEqual(model.noteMarkers.count, 1)
    }

    // MARK: - Marker position

    func testMarkerAnchorSurvivesSaveAndReopen() throws {
        let url = try makeFixture()
        let model = openModel(at: url)
        try addPageNote(
            to: model,
            point: CGPoint(x: 300, y: 400),
            style: NoteStickerStyle(motif: .shiba, palette: .mint)
        )
        let before = try marker(in: model)
        XCTAssertEqual(before.center.x, 300, accuracy: 0.01)
        XCTAssertEqual(before.center.y, 400, accuracy: 0.01)

        XCTAssertEqual(model.save(), .saved)
        let reopened = openModel(at: url)
        let after = try marker(in: reopened)
        XCTAssertEqual(after.center.x, before.center.x, accuracy: 0.01)
        XCTAssertEqual(after.center.y, before.center.y, accuracy: 0.01)
        XCTAssertEqual(after.center.x, 300, accuracy: 0.01)
        XCTAssertEqual(after.center.y, 400, accuracy: 0.01)
        XCTAssertEqual(after.style, before.style)
        XCTAssertEqual(after.bounds.minX, before.bounds.minX, accuracy: 0.01)
        XCTAssertEqual(after.bounds.minY, before.bounds.minY, accuracy: 0.01)
        XCTAssertEqual(after.bounds.width, before.bounds.width, accuracy: 0.01)
        XCTAssertEqual(after.bounds.height, before.bounds.height, accuracy: 0.01)
    }

    func testPDFKitRewritingRectDoesNotMoveAnAnchoredMarker() throws {
        let anchor = CGPoint(x: 311, y: 411)
        let url = try makeHandBuiltNoteFixture(
            bounds: CGRect(x: 300, y: 400, width: 22, height: 22),
            contents: "Rect rewrite",
            style: "{\"v\":1,\"motif\":\"otter\",\"palette\":\"honey\"}",
            anchor: anchor
        )
        let model = openModel(at: url)
        let before = try marker(in: model)
        XCTAssertEqual(before.center.x, 311, accuracy: 0.01)
        XCTAssertEqual(before.center.y, 411, accuracy: 0.01)
        XCTAssertEqual(model.save(), .saved)

        let reopened = try XCTUnwrap(PDFDocument(url: url))
        let note = try textNote(on: 0, in: reopened)
        XCTAssertEqual(note.bounds.width, 24, accuracy: 0.01, "PDFKit grows /Rect to 24×24")
        XCTAssertEqual(note.bounds.height, 24, accuracy: 0.01)

        let modelAfter = openModel(at: url)
        let after = try marker(in: modelAfter)
        XCTAssertEqual(after.center.x, anchor.x, accuracy: 0.01, "the anchor wins over /Rect")
        XCTAssertEqual(after.center.y, anchor.y, accuracy: 0.01)
        XCTAssertEqual(after.style.motif, .otter)
    }

    func testNonZeroCropBoxOriginUsesTheCropBoxCoordinateSpace() throws {
        let crop = CGRect(x: 20, y: 30, width: 500, height: 700)
        let url = try makeFixture(cropBox: crop)
        let model = openModel(at: url)
        let page = try XCTUnwrap(model.document?.page(at: 0))
        XCTAssertEqual(page.bounds(for: .cropBox), crop)

        let point = CGPoint(x: 120, y: 430)
        try addPageNote(to: model, point: point, style: NoteStickerStyle(motif: .bow, palette: .rose))

        let annotation = try textNote(on: 0, in: try XCTUnwrap(model.document))
        let nx = try XCTUnwrap(annotation.value(forAnnotationKey: NoteService.anchorXKey) as? NSNumber)
        let ny = try XCTUnwrap(annotation.value(forAnnotationKey: NoteService.anchorYKey) as? NSNumber)
        XCTAssertEqual(nx.doubleValue, 0.2, accuracy: 0.0001)
        XCTAssertEqual(ny.doubleValue, 400.0 / 700.0, accuracy: 0.0001)

        XCTAssertEqual(model.save(), .saved)
        let reopened = openModel(at: url)
        let after = try marker(in: reopened)
        XCTAssertEqual(after.center.x, point.x, accuracy: 0.01)
        XCTAssertEqual(after.center.y, point.y, accuracy: 0.01)
        XCTAssertEqual(try textNote(on: 0, in: try XCTUnwrap(reopened.document)).bounds.width, 24, accuracy: 0.01)
    }

    func testRotatedPageKeepsThePageSpaceAnchor() throws {
        let url = try makeFixture(rotation: 90)
        let model = openModel(at: url)
        let page = try XCTUnwrap(model.document?.page(at: 0))
        XCTAssertEqual(page.rotation, 90)

        let point = CGPoint(x: 280, y: 360)
        try addPageNote(to: model, point: point, style: NoteStickerStyle(motif: .cloud, palette: .sky))
        let before = try marker(in: model)
        XCTAssertEqual(before.center.x, point.x, accuracy: 0.01)
        XCTAssertEqual(before.center.y, point.y, accuracy: 0.01)

        XCTAssertEqual(model.save(), .saved)
        let reopened = openModel(at: url)
        XCTAssertEqual(try XCTUnwrap(reopened.document?.page(at: 0)).rotation, 90)
        let after = try marker(in: reopened)
        XCTAssertEqual(after.center.x, point.x, accuracy: 0.01)
        XCTAssertEqual(after.center.y, point.y, accuracy: 0.01)
    }

    func testSecondSaveDoesNotCompoundTheAnchor() throws {
        let url = try makeFixture()
        let model = openModel(at: url)
        try addPageNote(to: model, point: CGPoint(x: 240, y: 360), style: NoteStickerStyle(motif: .panda, palette: .sand))
        XCTAssertEqual(model.save(), .saved)
        let first = try marker(in: openModel(at: url))

        let secondModel = openModel(at: url)
        XCTAssertEqual(secondModel.save(), .saved)
        let second = try marker(in: openModel(at: url))

        XCTAssertEqual(second.center.x, first.center.x, accuracy: 0.001)
        XCTAssertEqual(second.center.y, first.center.y, accuracy: 0.001)
        XCTAssertEqual(second.bounds, first.bounds)
    }

    // MARK: - Undo and permissions

    func testStyleAndBodyChangesAreOneUndoActionRestoringTheWholeStyle() throws {
        let url = try makeFixture()
        let model = openModel(at: url)
        let added = try addPageNote(
            to: model,
            contents: "First body",
            style: NoteStickerStyle(motif: .bunny, palette: .honey)
        )
        XCTAssertEqual(model.markupUndoStack.count, 1)

        guard case .success = model.updateNote(
            added,
            contents: "Second body",
            style: NoteStickerStyle(motif: .cat, palette: .rose)
        ) else {
            return XCTFail("the edit must succeed")
        }
        XCTAssertEqual(model.markupUndoStack.count, 2, "one Save is one Undo entry")
        XCTAssertEqual(NoteService.style(of: try textNote(on: 0, in: try XCTUnwrap(model.document))).motif, .cat)

        XCTAssertTrue(model.undoMarkup())
        let restored = try textNote(on: 0, in: try XCTUnwrap(model.document))
        XCTAssertEqual(restored.contents, "First body")
        XCTAssertEqual(NoteService.style(of: restored), NoteStickerStyle(motif: .bunny, palette: .honey))

        XCTAssertTrue(model.redoMarkup())
        let redone = try textNote(on: 0, in: try XCTUnwrap(model.document))
        XCTAssertEqual(redone.contents, "Second body")
        XCTAssertEqual(NoteService.style(of: redone), NoteStickerStyle(motif: .cat, palette: .rose))
    }

    func testLockedContentsAllowsStyleButRejectsBody() throws {
        let url = try makeFixture()
        let model = openModel(at: url)
        let added = try addPageNote(
            to: model,
            contents: "Locked body",
            style: NoteStickerStyle(motif: .bunny, palette: .honey)
        )
        let annotation = try textNote(on: 0, in: try XCTUnwrap(model.document))
        annotation.setValue(
            NSNumber(value: MarkupPermissions.lockedContentsFlag),
            forAnnotationKey: .flags
        )

        guard case .failure(.permissionDenied) = model.updateNote(
            added,
            contents: "Changed body",
            style: NoteStickerStyle(motif: .bunny, palette: .honey)
        ) else {
            return XCTFail("LockedContents must refuse the body")
        }

        guard case let .success(updated) = model.updateNote(
            added,
            contents: "Locked body",
            style: NoteStickerStyle(motif: .puppy, palette: .mint)
        ) else {
            return XCTFail("LockedContents must allow the style")
        }
        XCTAssertEqual(updated.style, NoteStickerStyle(motif: .puppy, palette: .mint))
        XCTAssertEqual(annotation.contents, "Locked body")

        XCTAssertTrue(model.undoMarkup(), "a style-only edit is undoable under LockedContents")
        XCTAssertEqual(NoteService.style(of: annotation), NoteStickerStyle(motif: .bunny, palette: .honey))
        XCTAssertEqual(annotation.contents, "Locked body")
    }

    func testReadOnlyAndLockedRejectStyleChanges() throws {
        for flag in [MarkupPermissions.readOnlyFlag, MarkupPermissions.lockedFlag] {
            let url = try makeFixture(named: "protected-\(flag)")
            let model = openModel(at: url)
            let added = try addPageNote(
                to: model,
                contents: "Protected",
                style: NoteStickerStyle(motif: .star, palette: .honey)
            )
            let annotation = try textNote(on: 0, in: try XCTUnwrap(model.document))
            annotation.setValue(NSNumber(value: flag), forAnnotationKey: .flags)

            guard case .failure(.permissionDenied) = model.updateNote(
                added,
                contents: "Nope",
                style: NoteStickerStyle(motif: .heart, palette: .rose)
            ) else {
                return XCTFail("flag \(flag) must refuse a style change")
            }
            XCTAssertEqual(NoteService.style(of: annotation), NoteStickerStyle(motif: .star, palette: .honey))
        }
    }

    // MARK: - Draft protection

    func testStyleChangeCountsAsADraftChangeAndSurvivesDismissal() throws {
        let url = try makeFixture()
        let model = openModel(at: url)
        let store = NoteComposerStore()
        let page = try XCTUnwrap(model.document?.page(at: 0))
        let draft = try XCTUnwrap(model.pageNoteDraft(at: CGPoint(x: 300, y: 400), on: page))
        XCTAssertTrue(store.begin(
            mode: .create(draft),
            anchorRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            pageLabel: draft.pageLabel,
            excerpt: draft.excerpt,
            contents: "Draft body",
            style: .plain
        ))
        let session = try XCTUnwrap(store.session)
        let revision = store.revision
        XCTAssertFalse(session.hasUncommittedChanges)

        session.style = NoteStickerStyle(motif: .cherry, palette: .rose)
        XCTAssertTrue(session.hasUncommittedChanges)
        XCTAssertGreaterThan(store.revision, revision, "a motif change bumps the draft revision")

        store.closePopover()
        XCTAssertNotNil(store.session)
        XCTAssertEqual(store.session?.style, NoteStickerStyle(motif: .cherry, palette: .rose))
        store.discardIfClean()
        XCTAssertNotNil(store.session, "a dirty style must not be discarded by closing the popover")

        guard case .success = store.commit(using: model) else {
            return XCTFail("the style draft must commit")
        }
        let saved = try textNote(on: 0, in: try XCTUnwrap(model.document))
        XCTAssertEqual(NoteService.style(of: saved), NoteStickerStyle(motif: .cherry, palette: .rose))
        XCTAssertEqual(saved.contents, "Draft body")
        XCTAssertFalse(store.hasSession)
    }

    func testCancelWritesNoStyleToTheDocument() throws {
        let url = try makeFixture()
        let model = openModel(at: url)
        let store = NoteComposerStore()
        let page = try XCTUnwrap(model.document?.page(at: 0))
        let draft = try XCTUnwrap(model.pageNoteDraft(at: CGPoint(x: 300, y: 400), on: page))
        XCTAssertTrue(store.begin(
            mode: .create(draft),
            anchorRect: .zero,
            pageLabel: draft.pageLabel,
            excerpt: nil,
            contents: "Cancel me",
            style: NoteStickerStyle(motif: .letter, palette: .lavender)
        ))
        store.end()

        XCTAssertTrue(try XCTUnwrap(model.document?.page(at: 0)).annotations.isEmpty)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertTrue(model.noteMarkers.isEmpty)
    }

    func testOpeningAnotherDocumentKeepsTheStyleDraft() throws {
        let first = openModel(at: try makeFixture(named: "style-first"))
        let secondURL = try makeFixture(named: "style-second")
        let store = NoteComposerStore()
        let page = try XCTUnwrap(first.document?.page(at: 0))
        let draft = try XCTUnwrap(first.pageNoteDraft(at: CGPoint(x: 300, y: 400), on: page))
        XCTAssertTrue(store.begin(
            mode: .create(draft),
            anchorRect: .zero,
            pageLabel: draft.pageLabel,
            excerpt: nil,
            contents: "Style draft",
            style: NoteStickerStyle(motif: .bunny, palette: .mint)
        ))
        let session = try XCTUnwrap(store.session)
        session.style = NoteStickerStyle(motif: .panda, palette: .sand)

        XCTAssertTrue(first.open(url: secondURL), "a clean document may be replaced under a draft")

        store.reconcile(with: first)
        XCTAssertNotNil(store.session, "a dirty style draft survives a document replacement")
        XCTAssertEqual(
            store.session?.style,
            NoteStickerStyle(motif: .panda, palette: .sand)
        )
        XCTAssertEqual(store.session?.status(in: first), .documentReplaced)

        guard case .failure(.documentChanged) = store.commit(using: first) else {
            return XCTFail("committing into the replacement document must be refused")
        }
        XCTAssertEqual(
            store.session?.style,
            NoteStickerStyle(motif: .panda, palette: .sand),
            "the failed commit must keep the style selection"
        )
    }

    func testFailedSaveKeepsTheStyleSelection() throws {
        let url = try makeFixture()
        let model = openModel(at: url)
        let note = try addPageNote(
            to: model,
            contents: "Original",
            style: NoteStickerStyle(motif: .star, palette: .honey)
        )
        let store = NoteComposerStore()
        XCTAssertTrue(store.begin(
            mode: .edit(note),
            anchorRect: .zero,
            pageLabel: note.pageLabel,
            excerpt: note.excerpt,
            contents: note.contents,
            style: note.style
        ))
        let session = try XCTUnwrap(store.session)
        session.style = NoteStickerStyle(motif: .washi, palette: .lavender)

        XCTAssertTrue(model.deleteNote(note))
        guard case .failure = store.commit(using: model) else {
            return XCTFail("the note is gone, so the commit must fail")
        }
        XCTAssertNotNil(store.session)
        XCTAssertEqual(
            store.session?.style,
            NoteStickerStyle(motif: .washi, palette: .lavender),
            "a failed save keeps the motif and palette"
        )
    }

    // MARK: - Highlight coexistence

    func testStickerNoteDoesNotDisturbHighlightsOrUnderlines() throws {
        let url = try makeFixture()
        let model = openModel(at: url)
        let document = try XCTUnwrap(model.document)
        model.updateSelection(try selection(in: document, pageIndex: 0, from: 0))
        XCTAssertNotNil(model.addMarkup(.highlight))

        model.updateSelection(try selection(in: document, pageIndex: 0, from: 40))
        XCTAssertNotNil(model.addMarkup(.underline))

        try addPageNote(
            to: model,
            contents: "Sticker beside markup",
            style: NoteStickerStyle(motif: .roseStamp, palette: .sand)
        )
        XCTAssertEqual(model.save(), .saved)

        let reopened = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(reopened.page(at: 0))
        XCTAssertEqual(page.annotations.filter { $0.type == "Highlight" }.count, 1)
        XCTAssertEqual(page.annotations.filter { $0.type == "Underline" }.count, 1)
        let note = try textNote(on: 0, in: reopened)
        XCTAssertEqual(NoteService.style(of: note), NoteStickerStyle(motif: .roseStamp, palette: .sand))
        XCTAssertNil(
            page.annotations.first { $0.type == "Highlight" }?.value(forAnnotationKey: NoteService.styleKey),
            "markup annotations must not acquire sticker metadata"
        )
    }

    // MARK: - Asset loading

    func testEveryRuntimeAssetLoadsFromTheAssetCatalog() throws {
        let bundle = Bundle(for: NoteStickerStyleTests.self)
        for motif in NoteMotif.allCases {
            guard let name = motif.assetName else {
                XCTAssertEqual(motif, .plain)
                continue
            }
            let image = try XCTUnwrap(
                bundle.image(forResource: name),
                "\(name) must be compiled into the test bundle's asset catalog"
            )
            XCTAssertEqual(image.size.width, 256, accuracy: 0.01, "\(name) width")
            XCTAssertEqual(image.size.height, 256, accuracy: 0.01, "\(name) height")
            let tiff = try XCTUnwrap(image.tiffRepresentation, "\(name) must decode")
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff), "\(name) must have pixels")
            XCTAssertTrue(bitmap.hasAlpha, "\(name) must keep its transparency")
        }
    }
}
