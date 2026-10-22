import AppKit
import PDFKit
import XCTest
@testable import YoPDFCore

/// P2c notes through the reader model, against real PDFs and PDFKit.
///
/// A note is a standard `/Text` annotation, so every claim worth testing is a
/// PDFKit claim: what `/Contents` holds, where the rectangle landed, whether the
/// annotation survives a save and reopen, and what `/F` permits. A mock would
/// test the mock instead.
@MainActor
final class NoteAnnotationTests: XCTestCase {

    /// `tearDown()` is nonisolated in XCTest, so the cleanup list cannot be
    /// main-actor isolated. Tests run serially; nothing else touches it.
    nonisolated(unsafe) private var temporaryFiles: [URL] = []

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
            // Only the per-test directory this suite creates, never the shared
            // temporary directory itself.
            let directory = url.deletingLastPathComponent()
            if directory.lastPathComponent.hasPrefix("YoPDFTests-") {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        temporaryFiles.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures and helpers

    private func makeModel() -> PDFDocumentModel {
        PDFDocumentModel(access: SecurityScopeSpy())
    }

    private func makeFixture(
        pageCount: Int = 2,
        linesPerPage: Int = 4,
        named name: String = "notes"
    ) throws -> URL {
        let url = try PDFFixtureFactory.writeTemporaryParagraphPDF(
            pageCount: pageCount,
            linesPerPage: linesPerPage,
            named: name
        )
        temporaryFiles.append(url)
        return url
    }

    private func openModel(at url: URL) -> PDFDocumentModel {
        let model = makeModel()
        XCTAssertTrue(model.open(url: url), "the fixture must open")
        return model
    }

    private func selection(
        in document: PDFDocument,
        pageIndex: Int,
        from start: Int,
        to end: Int
    ) throws -> PDFSelection {
        let page = try XCTUnwrap(document.page(at: pageIndex))
        let length = (page.string ?? "").count
        let lower = min(max(start, 0), max(length - 1, 0))
        let upper = min(max(end, lower + 1), length)
        return try XCTUnwrap(
            document.selection(from: page, atCharacterIndex: lower, to: page, atCharacterIndex: upper)
        )
    }

    private func crossPageSelection(
        in document: PDFDocument,
        fromPage: Int,
        toPage: Int
    ) throws -> PDFSelection {
        let first = try XCTUnwrap(document.page(at: fromPage))
        let second = try XCTUnwrap(document.page(at: toPage))
        let firstLength = (first.string ?? "").count
        let secondLength = (second.string ?? "").count
        return try XCTUnwrap(
            document.selection(
                from: first,
                atCharacterIndex: max(firstLength - 20, 0),
                to: second,
                atCharacterIndex: min(30, max(secondLength - 1, 0))
            )
        )
    }

    private func notes(on pageIndex: Int, in model: PDFDocumentModel) throws -> [PDFAnnotation] {
        let page = try XCTUnwrap(model.document?.page(at: pageIndex))
        return page.annotations.filter { $0.type == "Text" }
    }

    private func note(on pageIndex: Int, in model: PDFDocumentModel) throws -> PDFAnnotation {
        try XCTUnwrap(
            notes(on: pageIndex, in: model).first,
            "the page must hold exactly one note"
        )
    }

    private func setFlags(_ flags: Int, on annotation: PDFAnnotation) {
        annotation.setValue(NSNumber(value: flags), forAnnotationKey: .flags)
    }

    private func hex(_ color: NSColor) -> String {
        MarkupColorPalette.hex(from: color) ?? ""
    }

    @discardableResult
    private func addSelectionNote(
        to model: PDFDocumentModel,
        contents: String = "A note about the selected text",
        paper: NotePaperColor = .honey
    ) throws -> NoteSelection {
        let draft = try XCTUnwrap(model.selectionNoteDraft(), "a selection must produce a draft")
        switch model.addNote(draft, contents: contents, paperColor: paper) {
        case let .success(note):
            return note
        case let .failure(error):
            XCTFail("note creation failed: \(error)")
            throw error
        }
    }

    @discardableResult
    private func addPageNote(
        to model: PDFDocumentModel,
        pageIndex: Int = 0,
        point: CGPoint = CGPoint(x: 300, y: 400),
        contents: String = "A page note",
        paper: NotePaperColor = .honey
    ) throws -> NoteSelection {
        let page = try XCTUnwrap(model.document?.page(at: pageIndex))
        let draft = try XCTUnwrap(model.pageNoteDraft(at: point, on: page))
        switch model.addNote(draft, contents: contents, paperColor: paper) {
        case let .success(note):
            return note
        case let .failure(error):
            XCTFail("page note creation failed: \(error)")
            throw error
        }
    }

    /// A PDF that already carries a third-party note, a highlight and a square.
    private func makeThirdPartyFixture(named name: String = "third-party") throws -> URL {
        let data = try PDFFixtureFactory.makeParagraphData(pageCount: 2, linesPerPage: 3)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))

        let note = PDFAnnotation(
            bounds: CGRect(x: 320, y: 520, width: 24, height: 24),
            forType: .text,
            withProperties: nil
        )
        note.iconType = .comment
        note.contents = "Third party note"
        note.color = NSColor(srgbRed: 0.9, green: 0.9, blue: 0.4, alpha: 1)
        page.addAnnotation(note)

        let highlight = PDFAnnotation(
            bounds: CGRect(x: 72, y: 700, width: 120, height: 16),
            forType: .highlight,
            withProperties: nil
        )
        highlight.color = NSColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1)
        page.addAnnotation(highlight)

        let square = PDFAnnotation(
            bounds: CGRect(x: 100, y: 380, width: 60, height: 40),
            forType: .square,
            withProperties: nil
        )
        page.addAnnotation(square)

        let written = try XCTUnwrap(document.dataRepresentation())
        let url = try PDFFixtureFactory.writeTemporaryFile(named: "\(name).pdf", contents: written)
        temporaryFiles.append(url)
        return url
    }

    /// A copy of `url` whose document permissions forbid commenting.
    ///
    /// PDFKit refuses to add annotations to a document that already forbids
    /// commenting, so the copy is made after the notes under test exist.
    private func makeCommentingRestrictedCopy(of url: URL) throws -> URL {
        let document = try XCTUnwrap(PDFDocument(url: url))
        let restricted = url.deletingLastPathComponent()
            .appendingPathComponent("restricted-\(UUID().uuidString).pdf")
        let wrote = document.write(
            to: restricted,
            withOptions: [
                PDFDocumentWriteOption.ownerPasswordOption: "yopdf-test-owner",
                PDFDocumentWriteOption.accessPermissionsOption: NSNumber(value: 1 << 0)
            ]
        )
        XCTAssertTrue(wrote, "the restricted fixture must be written")
        temporaryFiles.append(restricted)

        let reopened = try XCTUnwrap(PDFDocument(url: restricted))
        XCTAssertFalse(reopened.allowsCommenting, "the fixture must actually forbid commenting")
        return restricted
    }

    // MARK: - Selection notes

    func testSelectionNoteLandsOnTheSelectedPageWithAStandardTextAnnotation() throws {
        let model = openModel(at: try makeFixture())
        let document = try XCTUnwrap(model.document)
        model.updateSelection(try selection(in: document, pageIndex: 0, from: 0, to: 30))

        XCTAssertTrue(model.canAddSelectionNote)
        let draft = try XCTUnwrap(model.selectionNoteDraft())
        XCTAssertEqual(draft.pageIndex, 0)
        XCTAssertFalse(draft.isPageLevel)
        XCTAssertFalse((draft.excerpt ?? "").isEmpty, "the draft keeps a short quote")
        XCTAssertFalse(model.hasUnsavedChanges, "capturing an anchor is not an edit")

        let note = try addSelectionNote(to: model)

        let annotation = try self.note(on: 0, in: model)
        XCTAssertEqual(annotation.type, "Text", "the note must be a standard /Text annotation")
        XCTAssertEqual(annotation.contents, "A note about the selected text")
        XCTAssertEqual(hex(annotation.color), NotePaperColor.honey.hex)
        XCTAssertFalse(NoteService.isPageLevel(annotation))
        XCTAssertEqual(NoteService.excerpt(of: annotation), draft.excerpt)
        XCTAssertEqual(note.contents, annotation.contents)

        let pageBounds = try XCTUnwrap(model.document?.page(at: 0)).bounds(for: .cropBox)
        XCTAssertTrue(
            pageBounds.contains(annotation.bounds),
            "the marker must stay inside the page it belongs to"
        )
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertEqual(model.noteMarkers.count, 1)
        XCTAssertEqual(model.noteMarkers.first?.pageIndex, 0)
    }

    func testCrossPageSelectionAnchorsOnTheFirstPageOnly() throws {
        let model = openModel(at: try makeFixture())
        let document = try XCTUnwrap(model.document)
        model.updateSelection(try crossPageSelection(in: document, fromPage: 0, toPage: 1))

        let draft = try XCTUnwrap(model.selectionNoteDraft())
        XCTAssertEqual(draft.pageIndex, 0, "the anchor is the first page of the selection, not the current page")

        try addSelectionNote(to: model)

        XCTAssertEqual(try notes(on: 0, in: model).count, 1)
        XCTAssertTrue(
            try notes(on: 1, in: model).isEmpty,
            "a note must never be written to a page the selection only passed through"
        )

        let annotation = try note(on: 0, in: model)
        let pageBounds = try XCTUnwrap(model.document?.page(at: 0)).bounds(for: .cropBox)
        XCTAssertTrue(pageBounds.contains(annotation.bounds))
        XCTAssertEqual(model.noteMarkers.count, 1)
        XCTAssertEqual(model.noteMarkers.first?.pageIndex, 0)
    }

    // MARK: - Page notes

    func testPageNoteDoesNotInheritALiveSelection() throws {
        let model = openModel(at: try makeFixture())
        let document = try XCTUnwrap(model.document)
        model.updateSelection(try selection(in: document, pageIndex: 0, from: 0, to: 30))
        XCTAssertTrue(model.canAddSelectionNote)

        let page = try XCTUnwrap(model.document?.page(at: 1))
        let draft = try XCTUnwrap(model.pageNoteDraft(at: CGPoint(x: 300, y: 400), on: page))
        XCTAssertEqual(draft.pageIndex, 1)
        XCTAssertTrue(draft.isPageLevel)
        XCTAssertNil(draft.excerpt, "a page note must not borrow the selected text")

        switch model.addNote(draft, contents: "Placed by hand", paperColor: .mint) {
        case .success:
            break
        case let .failure(error):
            XCTFail("page note creation failed: \(error)")
        }

        XCTAssertTrue(try notes(on: 0, in: model).isEmpty, "the old selection's page is untouched")
        let annotation = try note(on: 1, in: model)
        XCTAssertEqual(annotation.contents, "Placed by hand")
        XCTAssertTrue(NoteService.isPageLevel(annotation))
        XCTAssertNil(NoteService.excerpt(of: annotation))
        XCTAssertEqual(hex(annotation.color), NotePaperColor.mint.hex)
        XCTAssertNil(model.currentSelection, "the consumed selection must not anchor the next note")
    }

    // MARK: - Serialization

    func testNoteBodyColourAndPositionSurviveSaveAndReopen() throws {
        let url = try makeFixture()
        let model = openModel(at: url)
        try addPageNote(
            to: model,
            point: CGPoint(x: 260, y: 430),
            contents: "Round trip body",
            paper: .lavender
        )
        let before = try note(on: 0, in: model).bounds
        XCTAssertEqual(model.save(), .saved)

        let reopened = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(reopened.page(at: 0))
        let notes = page.annotations.filter { $0.type == "Text" }
        XCTAssertEqual(notes.count, 1)
        let note = try XCTUnwrap(notes.first)
        XCTAssertEqual(note.contents, "Round trip body")
        XCTAssertEqual(NoteService.paperColor(of: note), .lavender)
        XCTAssertEqual(note.bounds.origin.x, before.origin.x, accuracy: 4)
        XCTAssertEqual(note.bounds.origin.y, before.origin.y, accuracy: 4)
        XCTAssertEqual(note.bounds.width, before.width, accuracy: 4)
        XCTAssertEqual(note.bounds.height, before.height, accuracy: 4)

        // The text is a plain `/Contents` string, and the style is a namespaced
        // custom key that another reader can ignore without losing the body.
        let raw = String(data: try Data(contentsOf: url), encoding: .isoLatin1) ?? ""
        XCTAssertTrue(raw.contains("/Contents"))
        XCTAssertTrue(raw.contains("/YoPDFNotePaper"))
        XCTAssertTrue(raw.contains("/Text"))
    }

    func testNoteSurvivesAReloadAndClearsHistory() throws {
        let model = openModel(at: try makeFixture())
        try addPageNote(to: model, contents: "Saved body")
        XCTAssertTrue(model.canUndoMarkup)

        XCTAssertEqual(model.save(), .saved)

        XCTAssertFalse(model.canUndoMarkup, "a save reloads the document and its history")
        XCTAssertFalse(model.canRedoMarkup)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(model.noteMarkers.count, 1, "the marker is rebuilt from the reloaded file")
        XCTAssertEqual(try note(on: 0, in: model).contents, "Saved body")
    }

    // MARK: - Editing

    func testEditingContentsIsDirtyAndUndoable() throws {
        let model = openModel(at: try makeFixture())
        let added = try addPageNote(to: model, contents: "First")
        let revision = model.editRevision

        switch model.updateNote(added, contents: "Second", paperColor: .honey) {
        case let .success(updated):
            XCTAssertEqual(updated.contents, "Second")
        case let .failure(error):
            XCTFail("editing failed: \(error)")
        }

        XCTAssertEqual(try note(on: 0, in: model).contents, "Second")
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertGreaterThan(model.editRevision, revision)

        XCTAssertTrue(model.undoMarkup())
        XCTAssertEqual(try note(on: 0, in: model).contents, "First")
        XCTAssertTrue(model.hasUnsavedChanges, "undo is an edit of the document too")

        XCTAssertTrue(model.redoMarkup())
        XCTAssertEqual(try note(on: 0, in: model).contents, "Second")
    }

    func testChangingThePaperIsOneUndoableEditThatKeepsTheBody() throws {
        let model = openModel(at: try makeFixture())
        let added = try addPageNote(to: model, contents: "Body", paper: .honey)
        XCTAssertEqual(model.markupUndoStack.count, 1)

        switch model.updateNote(added, contents: "Body", paperColor: .sky) {
        case .success:
            break
        case let .failure(error):
            XCTFail("recolouring failed: \(error)")
        }

        let annotation = try note(on: 0, in: model)
        XCTAssertEqual(hex(annotation.color), NotePaperColor.sky.hex)
        XCTAssertEqual(annotation.contents, "Body", "a colour change must not rewrite the body")
        XCTAssertEqual(model.markupUndoStack.count, 2, "one colour change is one history entry")

        XCTAssertTrue(model.undoMarkup())
        let restored = try note(on: 0, in: model)
        XCTAssertEqual(hex(restored.color), NotePaperColor.honey.hex)
        XCTAssertEqual(restored.contents, "Body")
    }

    func testSavingAnUnchangedNoteCreatesNoHistoryEntry() throws {
        let model = openModel(at: try makeFixture())
        let added = try addPageNote(to: model, contents: "Unchanged", paper: .sand)
        let stack = model.markupUndoStack.count
        let revision = model.editRevision

        switch model.updateNote(added, contents: "Unchanged", paperColor: .sand) {
        case .success:
            break
        case let .failure(error):
            XCTFail("a no-op save must succeed: \(error)")
        }

        XCTAssertEqual(model.markupUndoStack.count, stack)
        XCTAssertEqual(model.editRevision, revision)
    }

    // MARK: - Deleting

    func testDeletingANoteRemovesMarkerAndUndoRestoresIt() throws {
        let model = openModel(at: try makeFixture())
        let added = try addPageNote(to: model, contents: "Delete me")

        XCTAssertTrue(model.deleteNote(added))
        let page = try XCTUnwrap(model.document?.page(at: 0))
        XCTAssertTrue(page.annotations.isEmpty, "the note and PDFKit's popup both go")
        XCTAssertTrue(model.noteMarkers.isEmpty)
        XCTAssertTrue(model.hasUnsavedChanges)

        XCTAssertTrue(model.undoMarkup())
        let restored = try note(on: 0, in: model)
        XCTAssertEqual(restored.contents, "Delete me")
        XCTAssertEqual(model.noteMarkers.count, 1)
        XCTAssertLessThanOrEqual(
            page.annotations.filter { $0.type == "Popup" }.count,
            1,
            "undo must not duplicate the popup companion"
        )
    }

    func testUndoRemovesOnlyTheLastNote() throws {
        let model = openModel(at: try makeFixture())
        try addPageNote(to: model, pageIndex: 0, contents: "First page")
        try addPageNote(to: model, pageIndex: 1, contents: "Second page")

        XCTAssertTrue(model.undoMarkup())
        XCTAssertEqual(try notes(on: 0, in: model).count, 1)
        XCTAssertTrue(try notes(on: 1, in: model).isEmpty)
        XCTAssertEqual(try note(on: 0, in: model).contents, "First page")
    }

    // MARK: - Cancelling

    func testCapturingAnAnchorDoesNotTouchTheDocument() throws {
        let model = openModel(at: try makeFixture())
        let document = try XCTUnwrap(model.document)
        model.updateSelection(try selection(in: document, pageIndex: 0, from: 0, to: 25))
        let revision = model.editRevision

        // What the composer does when the user presses Cancel: it closes and
        // nothing else. No draft is committed, so nothing may have changed.
        XCTAssertNotNil(model.selectionNoteDraft())

        XCTAssertEqual(model.editRevision, revision)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertFalse(model.canUndoMarkup)
        XCTAssertTrue(model.noteMarkers.isEmpty)
        XCTAssertTrue(try XCTUnwrap(model.document?.page(at: 0)).annotations.isEmpty)
    }

    func testBlankNoteIsRefused() throws {
        let model = openModel(at: try makeFixture())
        let draft = try XCTUnwrap(model.pageNoteDraft(
            at: CGPoint(x: 200, y: 200),
            on: try XCTUnwrap(model.document?.page(at: 0))
        ))

        guard case let .failure(error) = model.addNote(draft, contents: " \n\t ", paperColor: .honey) else {
            return XCTFail("a blank note must be refused")
        }
        XCTAssertEqual(error, .emptyContents)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertFalse(model.canUndoMarkup)
        XCTAssertTrue(try XCTUnwrap(model.document?.page(at: 0)).annotations.isEmpty)
    }

    func testDraftFromAnotherDocumentIsRefused() throws {
        let first = openModel(at: try makeFixture(named: "first"))
        let second = openModel(at: try makeFixture(named: "second"))

        first.updateSelection(try selection(
            in: try XCTUnwrap(first.document),
            pageIndex: 0,
            from: 0,
            to: 20
        ))
        let draft = try XCTUnwrap(first.selectionNoteDraft())

        guard case let .failure(error) = second.addNote(draft, contents: "Wrong document", paperColor: .honey) else {
            return XCTFail("a draft from another document must be refused")
        }
        XCTAssertEqual(error, .documentChanged)
        XCTAssertFalse(second.hasUnsavedChanges)
        XCTAssertTrue(try XCTUnwrap(second.document?.page(at: 0)).annotations.isEmpty)
    }

    // MARK: - Permissions

    func testReadOnlyNoteRefusesEveryChangeAndUndo() throws {
        let model = openModel(at: try makeFixture())
        let added = try addPageNote(to: model, contents: "Protected")
        let annotation = try note(on: 0, in: model)
        setFlags(MarkupPermissions.readOnlyFlag, on: annotation)

        let permissions = model.notePermissions(for: added)
        XCTAssertFalse(permissions.canEditContents)
        XCTAssertFalse(permissions.canChangeStyle)
        XCTAssertFalse(permissions.canDelete)
        XCTAssertTrue(permissions.isReadOnly)

        guard case .failure(.permissionDenied) = model.updateNote(added, contents: "Changed", paperColor: .rose) else {
            return XCTFail("a ReadOnly note must refuse a body change")
        }
        XCTAssertFalse(model.deleteNote(added))

        // Undo is a mutation too: the preflight refuses it without discarding
        // the history or clearing the dirty state.
        XCTAssertFalse(model.undoMarkup())
        XCTAssertTrue(model.canUndoMarkup)
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertEqual(try note(on: 0, in: model).contents, "Protected")

        setFlags(0, on: annotation)
        XCTAssertTrue(model.undoMarkup(), "unlocking the note makes the same Undo available again")
        XCTAssertTrue(try notes(on: 0, in: model).isEmpty)
    }

    func testLockedContentsKeepsTheBodyButAllowsColourAndDelete() throws {
        let model = openModel(at: try makeFixture())
        let added = try addPageNote(to: model, contents: "Locked body", paper: .honey)
        let annotation = try note(on: 0, in: model)
        setFlags(MarkupPermissions.lockedContentsFlag, on: annotation)

        let permissions = model.notePermissions(for: added)
        XCTAssertFalse(permissions.canEditContents)
        XCTAssertTrue(permissions.canChangeStyle)
        XCTAssertTrue(permissions.canDelete)
        XCTAssertTrue(permissions.isContentsLocked)

        guard case .failure(.permissionDenied) = model.updateNote(added, contents: "New body", paperColor: .honey) else {
            return XCTFail("LockedContents must refuse a body change")
        }

        guard case .success = model.updateNote(added, contents: "Locked body", paperColor: .rose) else {
            return XCTFail("LockedContents must still allow a paper change")
        }
        XCTAssertEqual(hex(try note(on: 0, in: model).color), NotePaperColor.rose.hex)
        XCTAssertEqual(try note(on: 0, in: model).contents, "Locked body")

        XCTAssertTrue(model.deleteNote(added), "LockedContents does not protect deletion")
        XCTAssertTrue(try notes(on: 0, in: model).isEmpty)
    }

    /// The edit pipeline is the enforcement point; `updateNote` is an early
    /// refusal in front of it. This pins the pipeline on its own, so weakening
    /// either layer is visible in the suite.
    func testEditPipelineItselfRefusesALockedBody() throws {
        let model = openModel(at: try makeFixture())
        try addPageNote(to: model, contents: "Locked body")
        let annotation = try note(on: 0, in: model)
        setFlags(MarkupPermissions.lockedContentsFlag, on: annotation)

        let edit = MarkupEdit(changes: [
            .setContents(annotation: annotation, pageIndex: 0, from: "Locked body", to: "Nope")
        ])
        XCTAssertFalse(model.performMarkupEdit(edit))
        XCTAssertEqual(annotation.contents, "Locked body")
        XCTAssertFalse(model.canRedoMarkup, "a refused edit must not reach the history")
    }

    func testLockedContentsBlocksUndoOfABodyEdit() throws {
        let model = openModel(at: try makeFixture())
        let added = try addPageNote(to: model, contents: "Original")

        guard case .success = model.updateNote(added, contents: "Edited", paperColor: .honey) else {
            return XCTFail("the first body edit must succeed")
        }
        setFlags(MarkupPermissions.lockedContentsFlag, on: try note(on: 0, in: model))

        XCTAssertFalse(model.undoMarkup(), "undoing a body change needs LockedContents cleared")
        XCTAssertEqual(try note(on: 0, in: model).contents, "Edited")

        setFlags(0, on: try note(on: 0, in: model))
        XCTAssertTrue(model.undoMarkup())
        XCTAssertEqual(try note(on: 0, in: model).contents, "Original")
    }

    func testDocumentWithoutCommentingPermissionRefusesNotes() throws {
        let source = try makeFixture()
        let model = openModel(at: source)
        try addPageNote(to: model, contents: "Before the restriction")
        XCTAssertEqual(model.save(), .saved)

        let restricted = try makeCommentingRestrictedCopy(of: source)
        let locked = openModel(at: restricted)
        XCTAssertFalse(locked.canCreateNote)

        let page = try XCTUnwrap(locked.document?.page(at: 0))
        XCTAssertNil(locked.pageNoteDraft(at: CGPoint(x: 200, y: 200), on: page))

        let manual = NoteDraft(
            pageIndex: 0,
            bounds: CGRect(x: 200, y: 200, width: 22, height: 22),
            excerpt: nil,
            isPageLevel: true,
            document: try XCTUnwrap(locked.document)
        )
        guard case .failure(.permissionDenied) = locked.addNote(manual, contents: "Nope", paperColor: .honey) else {
            return XCTFail("a document that forbids commenting must refuse a new note")
        }

        let existing = try XCTUnwrap(locked.noteSelection(
            at: noteCenterOnPage0(in: locked),
            on: page
        ))
        XCTAssertEqual(existing.contents, "Before the restriction")
        XCTAssertEqual(locked.notePermissions(for: existing), .none)
        guard case .failure(.permissionDenied) = locked.updateNote(
            existing,
            contents: "Changed",
            paperColor: .honey
        ) else {
            return XCTFail("a restricted document must refuse a body change")
        }
        XCTAssertFalse(locked.deleteNote(existing))
    }

    private func noteCenterOnPage0(in model: PDFDocumentModel) -> CGPoint {
        guard let marker = model.noteMarkers.first(where: { $0.pageIndex == 0 }) else {
            return .zero
        }
        return CGPoint(x: marker.bounds.midX, y: marker.bounds.midY)
    }

    // MARK: - Third-party notes and coexistence

    func testThirdPartyNoteIsReadableEditableAndOtherAnnotationsSurvive() throws {
        let url = try makeThirdPartyFixture()
        let model = openModel(at: url)
        let page = try XCTUnwrap(model.document?.page(at: 0))
        let annotation = try XCTUnwrap(page.annotations.first { $0.type == "Text" })

        XCTAssertTrue(model.noteMarkers.isEmpty, "an untouched third-party note gets no sticker overlay")
        let selection = try XCTUnwrap(model.noteSelection(
            at: CGPoint(x: annotation.bounds.midX, y: annotation.bounds.midY),
            on: page
        ))
        XCTAssertFalse(selection.isYoPDFNote)
        XCTAssertEqual(selection.bounds, annotation.bounds, "the native bounds stay the hit target")
        XCTAssertEqual(selection.contents, "Third party note")
        XCTAssertEqual(selection.paperColor, .honey, "an unknown colour falls back to the default paper")
        XCTAssertTrue(model.notePermissions(for: selection).canEditContents)

        guard case .success = model.updateNote(
            selection,
            contents: "Edited third party note",
            paperColor: .honey
        ) else {
            return XCTFail("a standard /Text annotation from another app must be editable")
        }

        XCTAssertTrue(
            model.noteMarkers.isEmpty,
            "a body-only edit must not claim the third-party note's presentation"
        )
        XCTAssertEqual(model.save(), .saved)
        let reopened = try XCTUnwrap(PDFDocument(url: url))
        let reopenedPage = try XCTUnwrap(reopened.page(at: 0))
        XCTAssertEqual(
            reopenedPage.annotations.filter { $0.type == "Text" }.first?.contents,
            "Edited third party note"
        )
        XCTAssertEqual(reopenedPage.annotations.filter { $0.type == "Highlight" }.count, 1)
        XCTAssertEqual(reopenedPage.annotations.filter { $0.type == "Square" }.count, 1)
    }

    func testHiddenAnnotationIsNotAMarker() throws {
        let model = openModel(at: try makeFixture())
        try addPageNote(to: model, contents: "Hidden")
        let annotation = try note(on: 0, in: model)
        XCTAssertEqual(NoteService.markers(in: try XCTUnwrap(model.document)).count, 1)

        annotation.shouldDisplay = false
        XCTAssertTrue(
            NoteService.markers(in: try XCTUnwrap(model.document)).isEmpty,
            "a hidden annotation must not be drawn or hit-tested"
        )
        XCTAssertNil(model.noteSelection(
            at: CGPoint(x: annotation.bounds.midX, y: annotation.bounds.midY),
            on: try XCTUnwrap(model.document?.page(at: 0))
        ))
    }

    func testMarkerHitTestUsesTheMarkerRectangle() throws {
        let model = openModel(at: try makeFixture())
        let added = try addPageNote(to: model, point: CGPoint(x: 300, y: 400))
        let page = try XCTUnwrap(model.document?.page(at: 0))
        let centre = CGPoint(x: added.bounds.midX, y: added.bounds.midY)

        XCTAssertNotNil(model.noteSelection(at: centre, on: page))
        XCTAssertNil(model.noteSelection(at: CGPoint(x: centre.x + 60, y: centre.y + 60), on: page))
    }

    // MARK: - Save outcomes

    func testSaveConflictKeepsTheNoteAndItsHistory() throws {
        let url = try makeFixture()
        let model = openModel(at: url)
        try addPageNote(to: model, contents: "Conflict body")

        let replacement = try PDFFixtureFactory.makeParagraphData(pageCount: 2, linesPerPage: 3)
        try replacement.write(to: url, options: .atomic)

        guard case .conflict = model.save() else {
            return XCTFail("expected a conflict")
        }
        XCTAssertEqual(try Data(contentsOf: url), replacement, "the other app's bytes are not overwritten")
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertTrue(model.canUndoMarkup)
        XCTAssertEqual(try note(on: 0, in: model).contents, "Conflict body")
        XCTAssertEqual(model.noteMarkers.count, 1)
    }

    func testSaveAsCarriesTheNoteToTheCopy() throws {
        let url = try makeFixture()
        let model = openModel(at: url)
        try addPageNote(to: model, contents: "Copy body", paper: .rose)

        let copy = url.deletingLastPathComponent()
            .appendingPathComponent("note-copy-\(UUID().uuidString).pdf")
        temporaryFiles.append(copy)

        XCTAssertEqual(model.saveAs(to: copy, overwrite: true), .saved)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(model.noteMarkers.count, 1)

        let copied = try XCTUnwrap(PDFDocument(url: copy))
        let copiedNote = try XCTUnwrap(
            copied.page(at: 0)?.annotations.first { $0.type == "Text" }
        )
        XCTAssertEqual(copiedNote.contents, "Copy body")
        XCTAssertEqual(NoteService.paperColor(of: copiedNote), .rose)

        let original = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(
            (original.page(at: 0)?.annotations ?? []).filter { $0.type == "Text" }.isEmpty,
            "Save As must not modify the original file"
        )
    }
}
