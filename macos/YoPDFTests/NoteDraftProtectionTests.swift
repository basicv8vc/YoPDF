import AppKit
import PDFKit
import XCTest
@testable import YoPDFCore

/// The note draft that lives between the composer and the document.
///
/// Every test here is about one claim: text the user typed survives the things
/// the app does around it — a save, a reload, another annotation edit, a click
/// outside the popover, a quit sequence — and nothing is written to the PDF
/// until the user says so.
@MainActor
final class NoteDraftProtectionTests: XCTestCase {

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

    private func makeFixture(
        pageCount: Int = 2,
        linesPerPage: Int = 4,
        named name: String = "draft"
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
        let model = PDFDocumentModel(access: SecurityScopeSpy())
        XCTAssertTrue(model.open(url: url), "the fixture must open")
        return model
    }

    private func notes(on pageIndex: Int, in model: PDFDocumentModel) throws -> [PDFAnnotation] {
        let page = try XCTUnwrap(model.document?.page(at: pageIndex))
        return page.annotations.filter { NoteService.isTextAnnotation($0) }
    }

    @discardableResult
    private func addPageNote(
        to model: PDFDocumentModel,
        contents: String = "A page note"
    ) throws -> NoteSelection {
        let page = try XCTUnwrap(model.document?.page(at: 0))
        let draft = try XCTUnwrap(model.pageNoteDraft(at: CGPoint(x: 300, y: 400), on: page))
        switch model.addNote(draft, contents: contents, paperColor: .honey) {
        case let .success(note):
            return note
        case let .failure(error):
            XCTFail("note creation failed: \(error)")
            throw error
        }
    }

    /// Opens a composer for a new page note, as the reader does.
    @discardableResult
    private func beginPageNoteDraft(
        in model: PDFDocumentModel,
        store: NoteComposerStore,
        contents: String = "",
        paper: NotePaperColor = .honey
    ) throws -> NoteComposerSession {
        let page = try XCTUnwrap(model.document?.page(at: 0))
        let draft = try XCTUnwrap(model.pageNoteDraft(at: CGPoint(x: 300, y: 400), on: page))
        let opened = store.begin(
            mode: .create(draft),
            anchorRect: CGRect(x: 10, y: 10, width: 1, height: 1),
            pageLabel: draft.pageLabel,
            excerpt: draft.excerpt,
            contents: contents,
            paper: paper
        )
        XCTAssertTrue(opened, "a clean store must accept a new composer")
        return try XCTUnwrap(store.session)
    }

    @discardableResult
    private func beginEditDraft(
        for note: NoteSelection,
        in model: PDFDocumentModel,
        store: NoteComposerStore
    ) throws -> NoteComposerSession {
        let opened = store.begin(
            mode: .edit(note),
            anchorRect: CGRect(x: 10, y: 10, width: 1, height: 1),
            pageLabel: note.pageLabel,
            excerpt: note.excerpt,
            contents: note.contents,
            paper: note.paperColor
        )
        XCTAssertTrue(opened)
        return try XCTUnwrap(store.session)
    }

    private func work(_ model: PDFDocumentModel, _ store: NoteComposerStore) -> UnsavedWork {
        UnsavedWork(
            documentRevision: model.editRevision,
            draftRevision: store.revision,
            documentHasChanges: model.hasUnsavedChanges,
            draftHasChanges: store.hasUncommittedChanges
        )
    }

    // MARK: - The draft is not view state

    /// Case 12: the popover is dismissed and rebuilt — the same thing SwiftUI
    /// does when the user clicks outside, when the document is saved, and when
    /// another annotation changes. The text has to still be there.
    func testTypedTextSurvivesPopoverDismissalAndRebuild() throws {
        let model = openModel(at: try makeFixture())
        let store = NoteComposerStore()
        let session = try beginPageNoteDraft(in: model, store: store)

        session.contents = "Half a thought"
        session.paper = .mint
        XCTAssertTrue(store.hasUncommittedChanges)

        // The popover goes away without the user answering anything.
        store.closePopover()
        XCTAssertFalse(store.isPresented)
        XCTAssertEqual(store.session?.contents, "Half a thought", "the text is not popover state")
        XCTAssertEqual(store.session?.paper, .mint)

        // ...and comes back on the next render.
        store.isPresented = true
        XCTAssertEqual(store.session?.contents, "Half a thought")
        XCTAssertEqual(store.session?.id, session.id, "the same session, not a new empty one")
    }

    /// The expanded editor binds to the session rather than keeping a private
    /// copy. Those writes must advance the same revision the window close and
    /// quit guards inspect, and a dismissed popover must retain the draft.
    func testExpandedEditorChangesAdvanceTheProtectedDraftRevision() throws {
        let model = openModel(at: try makeFixture())
        let store = NoteComposerStore()
        let session = try beginPageNoteDraft(in: model, store: store)
        let revisionBeforeExpand = store.revision

        // These are the writes made through the expanded TextEditor and style
        // controls, which now bind directly to NoteComposerSession.
        session.contents = "Expanded editor text"
        var expandedStyle = session.style
        expandedStyle.palette = .mint
        session.style = expandedStyle

        XCTAssertGreaterThan(store.revision, revisionBeforeExpand)
        XCTAssertTrue(store.hasUncommittedChanges)
        XCTAssertEqual(
            ReaderPromptPolicy.prompt(for: .closeWindow, draftHasChanges: store.hasUncommittedChanges, documentHasChanges: false),
            .draft
        )
        XCTAssertEqual(
            ReaderPromptPolicy.prompt(for: .quit, draftHasChanges: store.hasUncommittedChanges, documentHasChanges: false),
            .draft
        )

        store.closePopover()
        XCTAssertEqual(store.session?.contents, "Expanded editor text")
        XCTAssertEqual(store.session?.style.palette, .mint)
        XCTAssertTrue(store.hasUncommittedChanges)
    }

    /// Cancel in the expanded sheet restores only the values captured when the
    /// sheet opened. Earlier compact-composer work remains dirty and protected.
    func testExpandedEditorCancelRestoresItsSnapshotAndKeepsEarlierDraftWork() throws {
        let model = openModel(at: try makeFixture())
        let store = NoteComposerStore()
        let session = try beginPageNoteDraft(in: model, store: store)

        session.contents = "Draft before expand"
        var compactStyle = session.style
        compactStyle.palette = .rose
        session.style = compactStyle
        let snapshot = session.snapshot()
        let revisionBeforeExpandedEdits = store.revision

        session.contents = "Discard this expanded edit"
        var expandedStyle = session.style
        expandedStyle.palette = .mint
        session.style = expandedStyle
        session.templateSelection.apply(NoteTemplate.builtIns()[1], to: session.contents)

        session.restore(from: snapshot)

        XCTAssertGreaterThan(store.revision, revisionBeforeExpandedEdits)
        XCTAssertEqual(session.contents, "Draft before expand")
        XCTAssertEqual(session.style, compactStyle)
        XCTAssertEqual(session.templateSelection, snapshot.templateSelection)
        XCTAssertTrue(store.hasUncommittedChanges, "the earlier compact draft is still protected")
        XCTAssertFalse(model.hasUnsavedChanges, "Cancel must not write anything to the PDF")
        XCTAssertTrue(try notes(on: 0, in: model).isEmpty)
    }

    /// Save from the expanded editor commits the live session values as one
    /// annotation, then drops the draft from the close/quit protection state.
    func testExpandedEditorSaveCommitsTheLiveSessionDraft() throws {
        let model = openModel(at: try makeFixture())
        let store = NoteComposerStore()
        let session = try beginPageNoteDraft(in: model, store: store)

        session.contents = "Saved from expanded editor"
        var expandedStyle = session.style
        expandedStyle.palette = .lavender
        expandedStyle.motif = .cat
        session.style = expandedStyle

        guard case .success = store.commit(using: model) else {
            return XCTFail("the expanded session must save")
        }

        XCTAssertNil(store.session)
        let annotation = try XCTUnwrap(try notes(on: 0, in: model).first)
        XCTAssertEqual(annotation.contents, "Saved from expanded editor")
        XCTAssertEqual(NoteService.style(of: annotation), expandedStyle)
        XCTAssertFalse(store.hasUncommittedChanges)
        XCTAssertTrue(model.hasUnsavedChanges, "the PDF still requires its normal document save")
    }

    /// Case 7: a composer nobody typed into is dropped silently. A confirmation
    /// for an empty draft would train the user to dismiss the real one.
    func testCleanDraftIsDroppedWithoutAsking() throws {
        let model = openModel(at: try makeFixture())
        let store = NoteComposerStore()
        let session = try beginPageNoteDraft(in: model, store: store)

        XCTAssertFalse(store.hasUncommittedChanges)
        XCTAssertFalse(work(model, store).hasChanges)

        store.closePopover()
        store.discardIfClean()

        XCTAssertNil(store.session)
        XCTAssertEqual(session.contents, "")
        XCTAssertFalse(store.isPresented)
    }

    /// Clicking another marker dismisses the popover first, so opening a second
    /// composer is a real path to losing the first draft.
    func testDirtyDraftIsNotReplacedByAnotherNote() throws {
        let model = openModel(at: try makeFixture())
        let store = NoteComposerStore()
        let session = try beginPageNoteDraft(in: model, store: store)
        session.contents = "Keep me"

        let page = try XCTUnwrap(model.document?.page(at: 1))
        let second = try XCTUnwrap(model.pageNoteDraft(at: CGPoint(x: 200, y: 200), on: page))
        let opened = store.begin(
            mode: .create(second),
            anchorRect: .zero,
            pageLabel: second.pageLabel,
            excerpt: nil,
            contents: "",
            paper: .honey
        )

        XCTAssertFalse(opened, "a draft with text must be resolved first")
        XCTAssertEqual(store.session?.contents, "Keep me")
    }

    // MARK: - Cancel writes nothing

    /// Case 8: Cancel is a true no-op — no annotation, no dirty state, no Undo
    /// entry.
    func testCancelWritesNothingToTheDocument() throws {
        let model = openModel(at: try makeFixture())
        let store = NoteComposerStore()
        let session = try beginPageNoteDraft(in: model, store: store)

        session.contents = "This will be discarded"
        session.paper = .rose
        store.end()

        XCTAssertNil(store.session)
        XCTAssertTrue(try notes(on: 0, in: model).isEmpty)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertFalse(model.canUndoMarkup)
        XCTAssertTrue(model.noteMarkers.isEmpty)
    }

    // MARK: - Save Note

    /// Case 10, first half: saving the note commits it to the in-memory
    /// document, and the composer closes because the text is no longer only
    /// there.
    func testSaveNoteCommitsToTheDocumentAndClosesTheDraft() throws {
        let model = openModel(at: try makeFixture())
        let store = NoteComposerStore()
        let session = try beginPageNoteDraft(in: model, store: store)
        session.contents = "Committed"
        session.paper = .sky

        guard case .success = store.commit(using: model) else {
            return XCTFail("the note must be committed")
        }

        XCTAssertNil(store.session)
        let annotation = try XCTUnwrap(try notes(on: 0, in: model).first)
        XCTAssertEqual(annotation.contents, "Committed")
        XCTAssertEqual(NoteService.paperColor(of: annotation), .sky)
        XCTAssertTrue(model.hasUnsavedChanges, "the document still has to be saved")
        XCTAssertTrue(model.canUndoMarkup, "committing the note is one Undo entry")
    }

    /// Case 9: the note was deleted while the composer was open. Nothing may be
    /// written to the object that is no longer on the page, and the text has to
    /// survive so the user can copy it.
    func testCommitRefusesAndKeepsTheTextWhenTheNoteIsGone() throws {
        let model = openModel(at: try makeFixture())
        let note = try addPageNote(to: model)
        model.abandonUnsavedChanges()

        let store = NoteComposerStore()
        let session = try beginEditDraft(for: note, in: model, store: store)
        session.contents = "Edited after the note disappeared"

        XCTAssertTrue(model.deleteNote(note))
        XCTAssertTrue(try notes(on: 0, in: model).isEmpty)

        guard case let .failure(error) = store.commit(using: model) else {
            return XCTFail("committing into a detached annotation must fail")
        }
        XCTAssertEqual(error, .annotationUnavailable)
        XCTAssertEqual(store.session?.contents, "Edited after the note disappeared")
        XCTAssertTrue(
            try notes(on: 0, in: model).isEmpty,
            "nothing may be re-created or redirected to another note"
        )
        XCTAssertEqual(session.status(in: model), .noteRemoved)
    }

    // MARK: - Another annotation edit

    /// Case 11: a Highlight bumps `annotationRevision`. That is not a reason to
    /// close a composer, and it must not touch the draft.
    func testHighlightingDoesNotDiscardTheDraft() throws {
        let model = openModel(at: try makeFixture())
        let note = try addPageNote(to: model)
        model.abandonUnsavedChanges()

        let store = NoteComposerStore()
        let session = try beginEditDraft(for: note, in: model, store: store)
        session.contents = "Still editing"

        let page = try XCTUnwrap(model.document?.page(at: 0))
        let text = try XCTUnwrap(page.string)
        model.updateSelection(
            try XCTUnwrap(model.document?.selection(
                from: page,
                atCharacterIndex: 0,
                to: page,
                atCharacterIndex: min(10, text.count)
            ))
        )
        XCTAssertNotNil(model.addMarkup(.highlight), "the highlight must be created")

        // What the reader does when `annotationRevision` changes.
        store.reconcile(with: model)

        XCTAssertEqual(store.session?.contents, "Still editing")
        XCTAssertEqual(session.status(in: model), .ready)
    }

    /// The same change closes a composer that has nothing to lose — the note it
    /// pointed at is gone, and leaving an empty popover behind would be noise.
    func testReconcileClosesOnlyAComposerWithNothingToLose() throws {
        let model = openModel(at: try makeFixture())
        let note = try addPageNote(to: model)
        model.abandonUnsavedChanges()

        let cleanStore = NoteComposerStore()
        try beginEditDraft(for: note, in: model, store: cleanStore)
        XCTAssertTrue(model.deleteNote(note))
        cleanStore.reconcile(with: model)
        XCTAssertNil(cleanStore.session)

        let other = try addPageNote(to: model, contents: "Second note")
        let dirtyStore = NoteComposerStore()
        let session = try beginEditDraft(for: other, in: model, store: dirtyStore)
        session.contents = "Typed but not saved"
        XCTAssertTrue(model.deleteNote(other))
        dirtyStore.reconcile(with: model)

        XCTAssertEqual(dirtyStore.session?.contents, "Typed but not saved")
        XCTAssertEqual(session.status(in: model), .noteRemoved)
    }

    /// Case 2, after the fact: if a document is replaced while a draft is open,
    /// the draft is kept and reports why it cannot be saved — it is never
    /// silently written into the new document.
    func testDocumentReplacementKeepsTheDraftAndExplainsWhy() throws {
        let first = try makeFixture(named: "first")
        let second = try makeFixture(named: "second")
        let model = openModel(at: first)

        let store = NoteComposerStore()
        let session = try beginPageNoteDraft(in: model, store: store)
        session.contents = "Anchored in the first document"

        XCTAssertTrue(model.open(url: second), "a clean document may be replaced")
        store.reconcile(with: model)

        XCTAssertEqual(store.session?.contents, "Anchored in the first document")
        XCTAssertEqual(session.status(in: model), .documentReplaced)
        XCTAssertTrue(
            try notes(on: 0, in: model).isEmpty,
            "the new document must not receive the old draft"
        )
    }

    // MARK: - Revision

    /// Case 6: the draft version never goes backwards, so an approval recorded
    /// for an earlier draft cannot match a later one.
    func testDraftRevisionOnlyEverIncreases() throws {
        let model = openModel(at: try makeFixture())
        let store = NoteComposerStore()

        let first = try beginPageNoteDraft(in: model, store: store)
        let atOpen = store.revision
        first.contents = "a"
        let afterTyping = store.revision
        first.paper = .sand
        let afterRecolour = store.revision

        store.end()
        let afterEnd = store.revision

        try beginPageNoteDraft(in: model, store: store)
        let secondOpen = store.revision

        XCTAssertGreaterThan(atOpen, 0)
        XCTAssertGreaterThan(afterTyping, atOpen)
        XCTAssertGreaterThan(afterRecolour, afterTyping)
        XCTAssertGreaterThan(afterEnd, afterRecolour)
        XCTAssertGreaterThan(secondOpen, afterEnd, "a new draft must not reuse an old version")
    }

    /// Case 6: `editRevision` alone cannot answer "did this window change?" —
    /// a draft edit has to move the combined revision even when the document
    /// never did.
    func testUnsavedWorkRevisionCoversTheDraft() throws {
        let model = openModel(at: try makeFixture())
        let store = NoteComposerStore()

        let before = work(model, store)
        XCTAssertFalse(before.hasChanges)

        let session = try beginPageNoteDraft(in: model, store: store)
        session.contents = "draft only"
        let after = work(model, store)

        XCTAssertTrue(after.hasChanges)
        XCTAssertFalse(after.documentHasChanges, "the document is still clean")
        XCTAssertGreaterThan(after.revision, before.revision)
        XCTAssertGreaterThan(
            after.revision,
            model.editRevision,
            "the draft half has to be visible on its own"
        )
    }

    // MARK: - Prompt order

    /// Cases 1–4: every action that could lose the draft asks about it first.
    func testTheDraftIsResolvedBeforeEveryRiskyAction() {
        let actions: [ReaderAction] = [
            .save, .saveAs, .open(URL(fileURLWithPath: "/tmp/other.pdf")),
            .closeWindow, .quit, .compose,
        ]
        for action in actions {
            XCTAssertEqual(
                ReaderPromptPolicy.prompt(for: action, draftHasChanges: true, documentHasChanges: false),
                .draft,
                "\(action) must ask about the draft"
            )
            XCTAssertEqual(
                ReaderPromptPolicy.prompt(for: action, draftHasChanges: true, documentHasChanges: true),
                .draft,
                "\(action) must ask about the draft even when the document is dirty too"
            )
        }
    }

    /// Case 7: nothing unsaved, nothing to ask.
    func testNothingIsAskedWhenNothingWouldBeLost() {
        let actions: [ReaderAction] = [
            .save, .saveAs, .open(URL(fileURLWithPath: "/tmp/other.pdf")),
            .closeWindow, .quit, .compose,
        ]
        for action in actions {
            XCTAssertEqual(
                ReaderPromptPolicy.prompt(for: action, draftHasChanges: false, documentHasChanges: false),
                .none,
                "\(action) must not ask about a clean window"
            )
        }
    }

    /// Case 2: after "Save Note" the document is dirty, so opening still has to
    /// go through the ordinary unsaved-changes question. Saving the file itself
    /// needs no second question.
    func testTheDocumentIsAskedAfterTheDraftIsResolved() {
        XCTAssertEqual(
            ReaderPromptPolicy.promptAfterDraft(
                for: .open(URL(fileURLWithPath: "/tmp/other.pdf")),
                documentHasChanges: true
            ),
            .document
        )
        XCTAssertEqual(
            ReaderPromptPolicy.promptAfterDraft(for: .closeWindow, documentHasChanges: true),
            .document
        )
        XCTAssertEqual(
            ReaderPromptPolicy.promptAfterDraft(for: .quit, documentHasChanges: true),
            .document
        )
        XCTAssertEqual(
            ReaderPromptPolicy.promptAfterDraft(for: .save, documentHasChanges: true),
            .none,
            "⌘S is the answer to the dirty document"
        )
        XCTAssertEqual(
            ReaderPromptPolicy.promptAfterDraft(for: .compose, documentHasChanges: true),
            .none
        )
    }

    // MARK: - Document save failure

    /// Case 10, second half: a document save that fails after the note was
    /// committed keeps both the note and its Undo history.
    func testAFailedDocumentSaveKeepsTheCommittedNoteAndItsHistory() throws {
        let url = try makeFixture()
        let model = openModel(at: url)
        let store = NoteComposerStore()

        let session = try beginPageNoteDraft(in: model, store: store)
        session.contents = "Committed, not yet on disk"
        guard case .success = store.commit(using: model) else {
            return XCTFail("the note must be committed")
        }

        // Another application changes the file between opening and saving.
        try Data("not the same bytes any more".utf8).write(to: url)

        guard case .conflict = model.save() else {
            return XCTFail("the save must be refused as a conflict")
        }

        XCTAssertTrue(model.hasUnsavedChanges, "the edits are still only in memory")
        XCTAssertTrue(model.canUndoMarkup, "the history must survive a failed save")
        let annotation = try XCTUnwrap(try notes(on: 0, in: model).first)
        XCTAssertEqual(annotation.contents, "Committed, not yet on disk")
    }

    // MARK: - Multi-window quit

    /// Stands in for a reader window: the same `UnsavedWork` composition the
    /// view installs on its close guard.
    @MainActor
    private final class DraftWindow: QuitConfirmingWindow {
        let model: PDFDocumentModel
        let store: NoteComposerStore
        private(set) var quitConfirmationRequests = 0
        private(set) var discardCount = 0

        init(model: PDFDocumentModel, store: NoteComposerStore) {
            self.model = model
            self.store = store
        }

        private var work: UnsavedWork {
            UnsavedWork(
                documentRevision: model.editRevision,
                draftRevision: store.revision,
                documentHasChanges: model.hasUnsavedChanges,
                draftHasChanges: store.hasUncommittedChanges
            )
        }

        var hasUnsavedChanges: Bool { work.hasChanges }
        var editRevision: Int { work.revision }

        func requestQuitConfirmation() {
            quitConfirmationRequests += 1
        }

        func discardUnsavedChangesForQuit() {
            discardCount += 1
            store.end()
            model.abandonUnsavedChanges()
        }
    }

    private func makeWindows() throws -> (a: DraftWindow, b: DraftWindow, coordinator: QuitCoordinator<DraftWindow>) {
        let a = DraftWindow(model: openModel(at: try makeFixture(named: "a")), store: NoteComposerStore())
        let b = DraftWindow(model: openModel(at: try makeFixture(named: "b")), store: NoteComposerStore())
        return (a, b, QuitCoordinator<DraftWindow>())
    }

    /// Case 5: A answers "Don't Save", B answers Cancel. A's draft is untouched
    /// — the approval was about the attempt, not about the text.
    func testCancelInOneWindowKeepsTheOtherWindowsDraft() throws {
        let (a, b, coordinator) = try makeWindows()
        let session = try beginPageNoteDraft(in: a.model, store: a.store)
        session.contents = "A's unsaved note"
        b.model.markEdited()

        let windows = [a, b]
        XCTAssertTrue(coordinator.nextWindowToAsk(among: windows) === a)

        coordinator.approveDiscard(of: a)
        XCTAssertNotNil(coordinator.nextWindowToAsk(among: windows), "B still has to answer")
        XCTAssertEqual(a.store.session?.contents, "A's unsaved note", "A's draft is still on screen")

        coordinator.cancel()

        XCTAssertEqual(a.store.session?.contents, "A's unsaved note")
        XCTAssertEqual(a.discardCount, 0)
        XCTAssertEqual(b.discardCount, 0)
        XCTAssertTrue(a.hasUnsavedChanges)
    }

    /// Case 5, the committed end: once every window agrees, the approved draft
    /// really is dropped.
    func testApprovedDraftsAreDiscardedOnlyWhenTerminationCommits() throws {
        let (a, b, coordinator) = try makeWindows()
        let session = try beginPageNoteDraft(in: a.model, store: a.store)
        session.contents = "A's unsaved note"
        b.model.markEdited()

        let windows = [a, b]
        coordinator.approveDiscard(of: a)
        XCTAssertNotNil(coordinator.nextWindowToAsk(among: windows))
        coordinator.approveDiscard(of: b)
        XCTAssertNil(coordinator.nextWindowToAsk(among: windows))

        XCTAssertEqual(a.store.session?.contents, "A's unsaved note", "not before commit")
        coordinator.commit(among: windows)

        XCTAssertNil(a.store.session)
        XCTAssertEqual(a.discardCount, 1)
        XCTAssertEqual(b.discardCount, 1)
    }

    /// Case 6: typing into the draft after answering invalidates the answer, so
    /// the window is asked again instead of having that text discarded.
    func testEditingTheDraftAfterApprovalInvalidatesIt() throws {
        let (a, b, coordinator) = try makeWindows()
        let session = try beginPageNoteDraft(in: a.model, store: a.store)
        session.contents = "first draft"
        b.model.markEdited()

        let windows = [a, b]
        coordinator.approveDiscard(of: a)
        XCTAssertTrue(coordinator.nextWindowToAsk(among: windows) === b)

        session.contents = "first draft, plus more"

        let next = coordinator.nextWindowToAsk(among: windows)
        XCTAssertTrue(next === a, "the stale approval must not survive the edit")
        XCTAssertEqual(a.quitConfirmationRequests, 0, "the coordinator only reports who is next")
        XCTAssertEqual(a.store.session?.contents, "first draft, plus more")
    }
}
