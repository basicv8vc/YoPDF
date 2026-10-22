import Foundation

/// A window the quit coordinator can ask about its unsaved edits.
///
/// `WindowCloseGuard` is the production conformer; tests use a small stand-in so
/// the quit sequence can be exercised without a window server.
///
/// The draft and the document are separate halves of the window's unsaved work.
/// A quit approval has to be able to say "drop the draft" without also saying
/// "drop the document's edits": the reader asks those two questions one after
/// the other, and the second answer may be Cancel.
@MainActor
public protocol QuitConfirmingWindow: AnyObject {
    /// Whether the window still holds edits that are not on disk, including a
    /// note that is still only in the composer.
    var hasUnsavedChanges: Bool { get }
    /// Monotonic revision of all of that work. See `UnsavedWork.revision`.
    var editRevision: Int { get }
    /// Whether the note composer holds text that is not in the document yet.
    var hasUnsavedDraft: Bool { get }
    /// Monotonic revision of the draft alone. See `NoteComposerStore.revision`.
    var draftRevision: Int { get }
    /// Whether the document holds edits that are not on disk.
    var hasUnsavedDocumentChanges: Bool { get }
    /// Monotonic revision of the document's edits. See `PDFDocumentModel.editRevision`.
    var documentRevision: Int { get }
    /// Presents the quit prompt for this window.
    func requestQuitConfirmation()
    /// Drops the draft now that termination is committed.
    func discardDraftForQuit()
    /// Drops the document's edits now that termination is committed.
    func discardDocumentChangesForQuit()
    /// Drops all of the window's edits now that termination is committed.
    func discardUnsavedChangesForQuit()
}

/// The default answers describe a window that has no note composer.
///
/// This keeps the document-only conformers — and the existing tests that use
/// them — working unchanged. A window that owns a composer overrides all of
/// these so the coordinator can treat its two halves separately.
@MainActor
public extension QuitConfirmingWindow {
    var hasUnsavedDraft: Bool { false }
    var draftRevision: Int { 0 }
    var hasUnsavedDocumentChanges: Bool { hasUnsavedChanges }
    var documentRevision: Int { editRevision }
    func discardDraftForQuit() {}
    func discardDocumentChangesForQuit() { discardUnsavedChangesForQuit() }
}

/// Which question a window still has to answer in this quit attempt.
public enum QuitConfirmationNeed: Equatable, Sendable {
    /// The composer holds text that has not been written to the document.
    case draft
    /// The document holds edits that are not in the file.
    case document
    /// Nothing is left to ask; termination may go ahead.
    case none
}

/// What "Discard Draft" means for the action that interrupted the composer.
///
/// Only a quit can defer: the window stays open while the other windows are
/// asked, and a Cancel there has to leave this window's draft intact. Every
/// other action continues in this window immediately, so its draft really is
/// being discarded.
public enum DraftDiscardResolution: Equatable, Sendable {
    case endedNow
    case deferredUntilQuitCommit(QuitConfirmationNeed)
}

/// The decision state of one quit attempt.
///
/// AppKit quits in a sequence: `applicationShouldTerminate` asks one window,
/// returns `.terminateCancel`, and only asks the next when the previous answer
/// says to continue. A "Don't Save" in that sequence is an answer about the
/// *attempt*, not a change to the document: the window stays open and keeps its
/// dirty state until the whole sequence succeeds.
///
/// The same is true of a draft. "Discard Draft" records an intent for this
/// attempt; it does not call `NoteComposerStore.end()`. The text stays on
/// screen until every window has answered and `commit` runs. A Cancel in this
/// window — or in any other window — drops the intents without touching a
/// single draft.
///
/// An approval is tied to the revisions it was given for. A later edit, a save,
/// or a different document in the same window makes it stale, so the window is
/// asked again rather than silently discarding work the user never approved.
@MainActor
public final class QuitCoordinator<Window: QuitConfirmingWindow> {

    private struct Approval {
        var documentRevision: Int
        var draftRevision: Int
        var discardsDocument: Bool
        var discardsDraft: Bool
    }

    private var approvals: [ObjectIdentifier: Approval] = [:]

    public init() {}

    // MARK: - Asking

    /// The window that must answer next, or `nil` when termination may go
    /// ahead. Approvals for closed windows and for work that changed since the
    /// answer are dropped first.
    public func nextWindowToAsk(among windows: [Window]) -> Window? {
        discardStaleApprovals(among: windows)
        return windows.first { confirmationNeed(for: $0) != .none }
    }

    /// What this window still has to answer. Reads the live state, so a draft
    /// edit after an approval turns the answer back into `.draft`.
    public func confirmationNeed(for window: Window) -> QuitConfirmationNeed {
        let id = ObjectIdentifier(window)
        if let approval = approvals[id], !isValid(approval, for: window) {
            approvals[id] = nil
        }
        let approval = approvals[id]
        if window.hasUnsavedDraft, approval?.discardsDraft != true {
            return .draft
        }
        if window.hasUnsavedDocumentChanges, approval?.discardsDocument != true {
            return .document
        }
        return .none
    }

    // MARK: - Recording answers

    /// Records "Don't Save" for the whole window in this attempt. The document
    /// and the draft are deliberately left untouched.
    public func approveDiscard(of window: Window) {
        recordApproval(for: window, discardsDraft: true, discardsDocument: true)
    }

    /// Records "Discard Draft" for this attempt without ending the draft.
    ///
    /// This is the only approval the reader takes when the user answers the
    /// draft prompt. It is intentionally narrower than `approveDiscard`: the
    /// document prompt still has to be answered separately.
    public func approveDraftDiscard(of window: Window) {
        recordApproval(for: window, discardsDraft: true)
    }

    /// Records "Don't Save" for the document's edits in this attempt.
    public func approveDocumentDiscard(of window: Window) {
        recordApproval(for: window, discardsDocument: true)
    }

    /// The reader's "Discard Draft" decision for an interrupted action.
    ///
    /// Quit defers the discard to `commit`; every other action can drop the
    /// draft immediately. Kept here so the production path and the tests make
    /// the same decision.
    public func resolveDraftDiscard(
        for action: ReaderAction,
        of window: Window
    ) -> DraftDiscardResolution {
        guard action == .quit else { return .endedNow }
        approveDraftDiscard(of: window)
        return .deferredUntilQuitCommit(confirmationNeed(for: window))
    }

    /// The attempt stopped before termination. No approval survives into the
    /// next attempt, so every still-dirty window will be asked again — and no
    /// deferred draft is ended here.
    public func cancel() {
        approvals.removeAll()
    }

    // MARK: - Committing

    /// Termination is confirmed. Now — and only now — the approved work is
    /// dropped. The revisions are checked again so an edit made after an answer
    /// keeps the window dirty and is never discarded by a stale approval.
    public func commit(among windows: [Window]) {
        discardStaleApprovals(among: windows)
        let approved = approvals
        approvals.removeAll()
        for window in windows {
            guard let approval = approved[ObjectIdentifier(window)] else { continue }
            let discardsDraft = approval.discardsDraft && window.hasUnsavedDraft
            let discardsDocument = approval.discardsDocument && window.hasUnsavedDocumentChanges
            if discardsDraft {
                window.discardDraftForQuit()
            }
            if discardsDocument {
                window.discardDocumentChangesForQuit()
            }
        }
    }

    // MARK: - Approval bookkeeping

    private func recordApproval(
        for window: Window,
        discardsDraft: Bool? = nil,
        discardsDocument: Bool? = nil
    ) {
        let id = ObjectIdentifier(window)
        var approval: Approval
        if let existing = approvals[id],
           existing.documentRevision == window.documentRevision,
           existing.draftRevision == window.draftRevision {
            approval = existing
        } else {
            approval = Approval(
                documentRevision: window.documentRevision,
                draftRevision: window.draftRevision,
                discardsDocument: false,
                discardsDraft: false
            )
        }
        if let discardsDraft { approval.discardsDraft = discardsDraft }
        if let discardsDocument { approval.discardsDocument = discardsDocument }
        approvals[id] = approval
    }

    private func discardStaleApprovals(among windows: [Window]) {
        let current = Dictionary(
            windows.map { (ObjectIdentifier($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        approvals = approvals.filter { id, approval in
            guard let window = current[id] else { return false }
            return isValid(approval, for: window)
        }
    }

    private func isValid(_ approval: Approval, for window: Window) -> Bool {
        guard window.hasUnsavedChanges else { return false }
        return window.documentRevision == approval.documentRevision
            && window.draftRevision == approval.draftRevision
    }
}
