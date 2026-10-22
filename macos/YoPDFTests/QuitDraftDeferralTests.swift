import AppKit
import PDFKit
import XCTest
@testable import YoPDFCore

/// The deferred half of a quit: a draft answered with "Discard Draft" is not
/// ended until the whole multi-window termination is committed.
///
/// These tests drive the same production calls the reader uses — the coordinator
/// decision in `QuitCoordinator.resolveDraftDiscard`, the live
/// `NoteComposerStore`, and the term/retry loop that mirrors `AppDelegate` — so a
/// regression that ends the session too early is visible here, not only in the
/// coordinator's bookkeeping.
@MainActor
final class QuitDraftDeferralTests: XCTestCase {

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

    private func makeFixture(named name: String) throws -> URL {
        let url = try PDFFixtureFactory.writeTemporaryParagraphPDF(
            pageCount: 2,
            linesPerPage: 4,
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

    private func makeWindow(named name: String) throws -> DraftWindow {
        DraftWindow(model: openModel(at: try makeFixture(named: name)), store: NoteComposerStore())
    }

    /// Opens a composer for a new page note and types into it, as the reader
    /// does before the user presses ⌘Q.
    @discardableResult
    private func typeNewNote(_ text: String, into window: DraftWindow) throws -> NoteComposerSession {
        let page = try XCTUnwrap(window.model.document?.page(at: 0))
        let draft = try XCTUnwrap(
            window.model.pageNoteDraft(at: CGPoint(x: 300, y: 400), on: page)
        )
        XCTAssertTrue(
            window.store.begin(
                mode: .create(draft),
                anchorRect: CGRect(x: 10, y: 10, width: 1, height: 1),
                pageLabel: draft.pageLabel,
                excerpt: draft.excerpt,
                contents: "",
                paper: .honey
            )
        )
        let session = try XCTUnwrap(window.store.session)
        session.contents = text
        return session
    }

    /// An edit draft whose target is deleted before Save, so committing it must
    /// fail without touching the typed text.
    private func typeUnsaveableEdit(into window: DraftWindow) throws -> NoteComposerSession {
        let page = try XCTUnwrap(window.model.document?.page(at: 0))
        let draft = try XCTUnwrap(
            window.model.pageNoteDraft(at: CGPoint(x: 300, y: 400), on: page)
        )
        let note: NoteSelection
        switch window.model.addNote(draft, contents: "Original note", paperColor: .honey) {
        case let .success(created):
            note = created
        case let .failure(error):
            throw error
        }
        window.model.abandonUnsavedChanges()

        XCTAssertTrue(
            window.store.begin(
                mode: .edit(note),
                anchorRect: CGRect(x: 10, y: 10, width: 1, height: 1),
                pageLabel: note.pageLabel,
                excerpt: note.excerpt,
                contents: note.contents,
                paper: note.paperColor
            )
        )
        let session = try XCTUnwrap(window.store.session)
        session.contents = "Text that cannot be saved"
        XCTAssertTrue(window.model.deleteNote(note))
        return session
    }

    // MARK: - Production mirror

    /// Stands in for `WindowCloseGuard` and the model/store behind it.
    @MainActor
    final class DraftWindow: QuitConfirmingWindow {
        let model: PDFDocumentModel
        let store: NoteComposerStore
        private(set) var quitConfirmationRequests = 0
        private(set) var draftDiscardCount = 0
        private(set) var documentDiscardCount = 0

        init(model: PDFDocumentModel, store: NoteComposerStore) {
            self.model = model
            self.store = store
        }

        var hasUnsavedChanges: Bool {
            model.hasUnsavedChanges || store.hasUncommittedChanges
        }

        var editRevision: Int { model.editRevision &+ store.revision }
        var hasUnsavedDraft: Bool { store.hasUncommittedChanges }
        var draftRevision: Int { store.revision }
        var hasUnsavedDocumentChanges: Bool { model.hasUnsavedChanges }
        var documentRevision: Int { model.editRevision }

        func requestQuitConfirmation() {
            quitConfirmationRequests += 1
        }

        func discardDraftForQuit() {
            draftDiscardCount += 1
            store.end()
        }

        func discardDocumentChangesForQuit() {
            documentDiscardCount += 1
            model.abandonUnsavedChanges()
        }

        func discardUnsavedChangesForQuit() {
            draftDiscardCount += 1
            documentDiscardCount += 1
            store.end()
            model.abandonUnsavedChanges()
        }
    }

    /// The reader's quit flow without SwiftUI: the same coordinator calls and
    /// the same alert choices, against real composer sessions.
    @MainActor
    final class QuitHarness {
        enum Prompt: Equatable {
            case draft
            case document
            case saveProblem
        }

        let windows: [DraftWindow]
        let coordinator: QuitCoordinator<DraftWindow>
        private(set) var prompt: Prompt?
        private(set) var pendingWindow: DraftWindow?
        private(set) var terminationAllowed = false

        init(_ windows: [DraftWindow]) {
            self.windows = windows
            self.coordinator = QuitCoordinator<DraftWindow>()
        }

        /// ⌘Q: `AppDelegate.applicationShouldTerminate`, then the window's
        /// `requestQuitConfirmation`.
        func quit() {
            terminationAllowed = false
            if let next = coordinator.nextWindowToAsk(among: windows) {
                ask(next)
            } else {
                commitTermination()
            }
        }

        /// "Discard Draft" in the alert. For quit this must only record the
        /// intent; the production coordinator decides that.
        func discardDraft() {
            guard let window = pendingWindow, prompt == .draft else {
                return XCTFail("discardDraft needs the draft prompt")
            }
            prompt = nil
            switch coordinator.resolveDraftDiscard(for: .quit, of: window) {
            case .endedNow:
                window.store.end()
                retryTermination()
            case let .deferredUntilQuitCommit(need):
                show(need)
            }
        }

        /// "Save Note" in the alert.
        func saveDraft() {
            guard let window = pendingWindow, prompt == .draft else {
                return XCTFail("saveDraft needs the draft prompt")
            }
            prompt = nil
            switch window.store.commit(using: window.model) {
            case .failure:
                // The quit stopped here, so the approvals other windows gave
                // belong to an attempt that is over.
                coordinator.cancel()
                prompt = .saveProblem
            case .success:
                show(coordinator.confirmationNeed(for: window))
            }
        }

        /// "Don't Save" in the document alert.
        func discardDocument() {
            guard let window = pendingWindow, prompt == .document else {
                return XCTFail("discardDocument needs the document prompt")
            }
            prompt = nil
            coordinator.approveDocumentDiscard(of: window)
            retryTermination()
        }

        /// "Save" in the document alert.
        func saveDocument() {
            guard let window = pendingWindow, prompt == .document else {
                return XCTFail("saveDocument needs the document prompt")
            }
            prompt = nil
            let deferredDraft = window.store.hasUncommittedChanges
            switch window.model.save() {
            case .saved, .savedUnverified:
                if deferredDraft {
                    coordinator.approveDraftDiscard(of: window)
                }
                retryTermination()
            default:
                coordinator.cancel()
                prompt = .saveProblem
            }
        }

        /// The alert's Cancel button.
        func cancel() {
            prompt = nil
            coordinator.cancel()
        }

        /// What the reader does after resolving one stage: ask the next window,
        /// or let termination commit when nothing is left.
        private func retryTermination() {
            if let next = coordinator.nextWindowToAsk(among: windows) {
                ask(next)
            } else {
                commitTermination()
            }
        }

        private func ask(_ window: DraftWindow) {
            pendingWindow = window
            window.requestQuitConfirmation()
            show(coordinator.confirmationNeed(for: window))
        }

        private func show(_ need: QuitConfirmationNeed) {
            switch need {
            case .draft:
                prompt = .draft
            case .document:
                prompt = .document
            case .none:
                retryTermination()
            }
        }

        private func commitTermination() {
            coordinator.commit(among: windows)
            terminationAllowed = true
            prompt = nil
        }
    }

    // MARK: - A. Draft then Document Cancel, one window

    /// Case A: discarding the draft and then cancelling the document prompt in
    /// the same window must leave every character in the composer.
    func testDraftThenDocumentCancelKeepsTheDraft() throws {
        let window = try makeWindow(named: "a")
        try typeNewNote("A's unsaved note", into: window)
        window.model.markEdited()
        let harness = QuitHarness([window])

        harness.quit()
        XCTAssertEqual(harness.prompt, .draft)

        harness.discardDraft()
        XCTAssertEqual(harness.prompt, .document, "the document still has to be answered")
        XCTAssertEqual(
            window.store.session?.contents,
            "A's unsaved note",
            "the draft must survive the first answer"
        )

        harness.cancel()
        XCTAssertFalse(harness.terminationAllowed)
        XCTAssertEqual(window.store.session?.contents, "A's unsaved note")
        XCTAssertTrue(window.store.hasUncommittedChanges)
        XCTAssertTrue(window.model.hasUnsavedChanges)
        XCTAssertEqual(window.draftDiscardCount, 0, "nothing was committed, so nothing was dropped")
        XCTAssertEqual(
            harness.coordinator.confirmationNeed(for: window),
            .draft,
            "cancel forgets the draft approval as well as the document one"
        )
    }

    // MARK: - B. A discards, B cancels

    /// Case B: A approves discarding its draft, then B cancels the quit. A's
    /// draft must still be there even though its own window already answered.
    func testCancelInAnotherWindowKeepsTheApprovedDraft() throws {
        let a = try makeWindow(named: "a")
        let b = try makeWindow(named: "b")
        try typeNewNote("A's unsaved note", into: a)
        b.model.markEdited()
        let harness = QuitHarness([a, b])

        harness.quit()
        XCTAssertEqual(harness.prompt, .draft)
        XCTAssertTrue(harness.pendingWindow === a)

        harness.discardDraft()
        XCTAssertEqual(harness.prompt, .document)
        XCTAssertTrue(harness.pendingWindow === b, "A is resolved, B is asked next")

        harness.cancel()
        XCTAssertFalse(harness.terminationAllowed)
        XCTAssertEqual(a.store.session?.contents, "A's unsaved note")
        XCTAssertTrue(a.store.hasUncommittedChanges)
        XCTAssertEqual(a.draftDiscardCount, 0)
        XCTAssertTrue(b.model.hasUnsavedChanges)
        XCTAssertEqual(b.documentDiscardCount, 0)
    }

    /// Case B, style half: a motif/palette change is draft state too. Cancelling
    /// the quit in another window must keep both windows' style selections.
    func testCancelInAnotherWindowKeepsStyleSelections() throws {
        let a = try makeWindow(named: "style-a")
        let b = try makeWindow(named: "style-b")
        let sessionA = try typeNewNote("A's styled note", into: a)
        sessionA.style = NoteStickerStyle(motif: .cherry, palette: .rose)
        let sessionB = try typeNewNote("B's styled note", into: b)
        sessionB.style = NoteStickerStyle(motif: .shiba, palette: .mint)
        let harness = QuitHarness([a, b])

        harness.quit()
        XCTAssertEqual(harness.prompt, .draft)
        XCTAssertTrue(harness.pendingWindow === a)

        harness.discardDraft()
        XCTAssertEqual(harness.prompt, .draft, "B still has to answer its own draft")
        XCTAssertTrue(harness.pendingWindow === b)

        harness.cancel()
        XCTAssertFalse(harness.terminationAllowed)
        XCTAssertEqual(
            a.store.session?.style,
            NoteStickerStyle(motif: .cherry, palette: .rose)
        )
        XCTAssertEqual(
            b.store.session?.style,
            NoteStickerStyle(motif: .shiba, palette: .mint)
        )
        XCTAssertTrue(a.store.hasUncommittedChanges)
        XCTAssertTrue(b.store.hasUncommittedChanges)
        XCTAssertEqual(a.draftDiscardCount, 0)
        XCTAssertEqual(b.draftDiscardCount, 0)
    }

    // MARK: - C. Both approve, commit is the only discard point

    /// Case C: once every window agrees, the approved draft is dropped by the
    /// commit — not while the other window is still deciding.
    func testApprovedDraftIsDiscardedOnlyWhenQuitCommits() throws {
        let a = try makeWindow(named: "a")
        let b = try makeWindow(named: "b")
        try typeNewNote("A's unsaved note", into: a)
        b.model.markEdited()
        let harness = QuitHarness([a, b])

        harness.quit()
        harness.discardDraft()
        XCTAssertEqual(
            a.store.session?.contents,
            "A's unsaved note",
            "B has not answered yet, so the quit is not committed"
        )
        XCTAssertEqual(a.draftDiscardCount, 0)

        harness.discardDocument()
        XCTAssertTrue(harness.terminationAllowed)
        XCTAssertNil(a.store.session)
        XCTAssertEqual(a.draftDiscardCount, 1)
        XCTAssertEqual(b.documentDiscardCount, 1)
        XCTAssertFalse(b.model.hasUnsavedChanges)
    }

    // MARK: - D. A later edit invalidates the draft approval

    /// Case D: typing after "Discard Draft" makes the approval stale; the
    /// window has to answer the draft prompt again instead of losing the new
    /// text.
    func testEditingTheDraftAfterApprovalAsksAgain() throws {
        let a = try makeWindow(named: "a")
        let b = try makeWindow(named: "b")
        let session = try typeNewNote("first draft", into: a)
        b.model.markEdited()
        let harness = QuitHarness([a, b])

        harness.quit()
        harness.discardDraft()
        XCTAssertEqual(harness.prompt, .document)
        XCTAssertTrue(harness.pendingWindow === b)

        session.contents = "first draft, plus more"

        XCTAssertEqual(
            harness.coordinator.confirmationNeed(for: a),
            .draft,
            "the approval was for the old draft revision"
        )
        XCTAssertTrue(
            harness.coordinator.nextWindowToAsk(among: harness.windows) === a,
            "A is asked again before termination can commit"
        )
        XCTAssertEqual(a.store.session?.contents, "first draft, plus more")
        XCTAssertEqual(a.draftDiscardCount, 0)
    }

    // MARK: - E. Both halves dirty, both approved

    /// Case E: a window with a dirty draft and a dirty document resolves both
    /// prompts in order and commits both discards only at the end.
    func testBothDraftAndDocumentAreDiscardedAtCommit() throws {
        let window = try makeWindow(named: "a")
        try typeNewNote("A's unsaved note", into: window)
        window.model.markEdited()
        let harness = QuitHarness([window])

        harness.quit()
        XCTAssertEqual(harness.prompt, .draft)
        harness.discardDraft()
        XCTAssertEqual(harness.prompt, .document)
        XCTAssertNotNil(window.store.session, "the document answer is still outstanding")

        harness.discardDocument()
        XCTAssertTrue(harness.terminationAllowed)
        XCTAssertNil(window.store.session)
        XCTAssertFalse(window.model.hasUnsavedChanges)
        XCTAssertEqual(window.draftDiscardCount, 1)
        XCTAssertEqual(window.documentDiscardCount, 1)
    }

    // MARK: - F. A failed Save Note stops the quit

    /// Case F: when the note cannot be written, the quit must not continue and
    /// the original text must still be in the composer.
    func testFailedNoteSaveStopsTheQuitAndKeepsTheText() throws {
        let a = try makeWindow(named: "a")
        let b = try makeWindow(named: "b")
        let session = try typeUnsaveableEdit(into: a)
        b.model.markEdited()
        let harness = QuitHarness([a, b])

        harness.quit()
        XCTAssertEqual(harness.prompt, .draft)
        XCTAssertTrue(harness.pendingWindow === a)

        harness.saveDraft()
        XCTAssertEqual(harness.prompt, .saveProblem)
        XCTAssertFalse(harness.terminationAllowed)
        XCTAssertEqual(a.store.session?.contents, "Text that cannot be saved")
        XCTAssertTrue(a.store.session === session, "the same draft, not a copy")
        XCTAssertEqual(a.quitConfirmationRequests, 1)
        XCTAssertEqual(b.quitConfirmationRequests, 0, "the quit stopped before B")
        XCTAssertEqual(a.draftDiscardCount, 0)
        XCTAssertEqual(a.documentDiscardCount, 0)
    }

    /// A failed Save Note in one window ends the whole quit attempt, so an
    /// earlier window's Don't Save must not survive into the next ⌘Q.
    func testFailedNoteSaveClearsAnotherWindowsApproval() throws {
        let a = try makeWindow(named: "a")
        let b = try makeWindow(named: "b")
        a.model.markEdited()
        let session = try typeUnsaveableEdit(into: b)
        // B's deleted note is not the point of this test: leave B with only the
        // failing draft, so the document prompt belongs to A.
        b.model.abandonUnsavedChanges()
        let harness = QuitHarness([a, b])

        harness.quit()
        XCTAssertEqual(harness.prompt, .document)
        XCTAssertTrue(harness.pendingWindow === a)
        harness.discardDocument()
        XCTAssertEqual(harness.prompt, .draft)
        XCTAssertTrue(harness.pendingWindow === b)

        harness.saveDraft()
        XCTAssertEqual(harness.prompt, .saveProblem)
        XCTAssertFalse(harness.terminationAllowed)
        XCTAssertTrue(b.store.session === session, "the text that failed to save is still here")
        XCTAssertEqual(b.store.session?.contents, "Text that cannot be saved")
        XCTAssertEqual(harness.coordinator.confirmationNeed(for: b), .draft)

        harness.quit()
        XCTAssertEqual(
            harness.prompt,
            .document,
            "A must be asked again: its Don't Save belonged to the failed attempt"
        )
        XCTAssertTrue(harness.pendingWindow === a)
        XCTAssertEqual(a.quitConfirmationRequests, 2)
        XCTAssertEqual(b.quitConfirmationRequests, 1)
    }

    // MARK: - G. A later ⌘Q asks the approved draft again

    /// Case G: after another window cancels, the next quit attempt must not
    /// reuse the old draft approval.
    func testANewQuitAsksThePreviouslyApprovedDraftAgain() throws {
        let a = try makeWindow(named: "a")
        let b = try makeWindow(named: "b")
        try typeNewNote("A's unsaved note", into: a)
        b.model.markEdited()
        let harness = QuitHarness([a, b])

        harness.quit()
        harness.discardDraft()
        XCTAssertEqual(harness.prompt, .document)
        harness.cancel()
        XCTAssertEqual(a.quitConfirmationRequests, 1)

        harness.quit()
        XCTAssertEqual(harness.prompt, .draft, "the cancelled attempt's approval is gone")
        XCTAssertTrue(harness.pendingWindow === a)
        XCTAssertEqual(a.quitConfirmationRequests, 2)
        XCTAssertEqual(a.store.session?.contents, "A's unsaved note")
        XCTAssertEqual(a.draftDiscardCount, 0)
    }

    // MARK: - The document revision is part of the same approval

    /// Case 6, document half: an edit after "Discard Draft" invalidates the
    /// draft approval even when the draft itself did not change.
    func testEditingTheDocumentAfterDraftApprovalAsksAgain() throws {
        let a = try makeWindow(named: "a")
        let b = try makeWindow(named: "b")
        try typeNewNote("A's unsaved note", into: a)
        a.model.markEdited()
        b.model.markEdited()
        let harness = QuitHarness([a, b])

        harness.quit()
        harness.discardDraft()
        XCTAssertEqual(harness.prompt, .document)
        XCTAssertTrue(harness.pendingWindow === a, "A's document prompt comes next")

        a.model.markEdited()

        XCTAssertEqual(
            harness.coordinator.confirmationNeed(for: a),
            .draft,
            "the approval was for the old document revision"
        )
        XCTAssertTrue(harness.coordinator.nextWindowToAsk(among: harness.windows) === a)
        XCTAssertEqual(a.store.session?.contents, "A's unsaved note")
        XCTAssertEqual(a.draftDiscardCount, 0)
    }

    // MARK: - Saving the document keeps the deferred draft decision

    /// A document save is not a new edit to the draft. The deferred discard
    /// stays valid, so quitting commits it without asking a second time.
    func testSavingTheDocumentKeepsTheDeferredDraftApproved() throws {
        let window = try makeWindow(named: "a")
        try typeNewNote("A's unsaved note", into: window)
        window.model.markEdited()
        let harness = QuitHarness([window])

        harness.quit()
        harness.discardDraft()
        XCTAssertEqual(harness.prompt, .document)

        harness.saveDocument()
        XCTAssertTrue(harness.terminationAllowed)
        XCTAssertNil(window.store.session)
        XCTAssertFalse(window.model.hasUnsavedChanges)
        XCTAssertEqual(window.draftDiscardCount, 1)
        XCTAssertEqual(window.documentDiscardCount, 0, "the document was saved, not discarded")
    }
}
