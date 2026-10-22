import AppKit
import Foundation
import PDFKit

// MARK: - Unsaved work

/// What one window would lose if it closed without asking.
///
/// The document's own revision is not enough to answer that question. A note
/// that is still only in the composer has never been written to the PDF, so
/// `PDFDocumentModel` knows nothing about it; treating `editRevision` as "all
/// the unsaved work in this window" is exactly how a quit approval ends up
/// covering text the user typed after answering.
///
/// Both halves only ever increase, so their sum does too: a change to either one
/// is visible to whoever recorded the approval.
public struct UnsavedWork: Equatable, Sendable {

    public let documentRevision: Int
    public let draftRevision: Int
    public let documentHasChanges: Bool
    public let draftHasChanges: Bool

    public init(
        documentRevision: Int,
        draftRevision: Int,
        documentHasChanges: Bool,
        draftHasChanges: Bool
    ) {
        self.documentRevision = documentRevision
        self.draftRevision = draftRevision
        self.documentHasChanges = documentHasChanges
        self.draftHasChanges = draftHasChanges
    }

    public var hasChanges: Bool { documentHasChanges || draftHasChanges }

    /// Monotonic across both halves. Deliberately a sum rather than "the
    /// document's revision if it is dirty": a draft edit has to invalidate an
    /// approval even when the document itself never moved.
    public var revision: Int { documentRevision &+ draftRevision }
}

// MARK: - Draft status

/// Whether the note a composer is working on still exists.
///
/// Read from the document on every render rather than cached: another
/// application, an Undo, or a document replacement can invalidate the target
/// while the composer is open, and the composer must say so instead of writing
/// into an object that is no longer on the page.
public enum NoteDraftStatus: Equatable, Sendable {
    case ready
    /// The anchor was captured in a document that has since been replaced.
    case documentReplaced
    /// The annotation this composer edits is no longer attached to its page.
    case noteRemoved
    /// The document no longer accepts new annotations.
    case commentingDisabled

    public var isReady: Bool { self == .ready }
}

// MARK: - Session

/// One open note composer, as data rather than as view state.
///
/// The body and the paper colour are still **not** in the document: Save is the
/// only thing that writes, which is what keeps Cancel a true no-op. But they are
/// no longer `@State` inside the popover either. SwiftUI throws a popover's
/// state away when the popover is rebuilt, and the popover is rebuilt by saving
/// the document, by another annotation edit, and by any click outside it.
/// Holding the draft here means none of those can quietly discard what the user
/// typed.
@MainActor
public final class NoteComposerSession: ObservableObject, Identifiable {

    /// What Save means: adding a note at a captured anchor, or changing one that
    /// is already in the document.
    public enum Mode {
        case create(NoteDraft)
        case edit(NoteSelection)
    }

    public let id = UUID()
    public let mode: Mode
    /// Where the popover's arrow points, in the reader's top-left space.
    public let anchorRect: CGRect
    public let pageLabel: String
    public let excerpt: String?
    /// What the draft looked like when the composer opened. `hasUncommittedChanges`
    /// is measured against these, not against the document.
    public let initialContents: String
    public let initialStyle: NoteStickerStyle

    /// Kept for PR #6 callers/tests: the paper is part of the style now.
    public var initialPaper: NotePaperColor { initialStyle.palette }

    @Published public var contents: String {
        didSet { noteChanged() }
    }

    /// The complete appearance being edited. Motif and palette are one value so
    /// a single revision bump covers either change.
    @Published public var style: NoteStickerStyle {
        didSet { noteChanged() }
    }

    /// Paper-only accessor used by the existing palette row and tests.
    public var paper: NotePaperColor {
        get { style.palette }
        set {
            var updated = style
            updated.palette = newValue
            style = updated
        }
    }

    /// Kept here so expanding the editor survives a popover rebuild.
    @Published public var isExpanded: Bool = false

    /// Version of this draft, used to keep a quit approval honest.
    ///
    /// Assigned by the owning `NoteComposerStore` from a counter that is global
    /// to the window, not to this session: a value that restarted at zero for
    /// each new draft could let an approval recorded for an earlier draft match
    /// a later one.
    public internal(set) var revision: Int = 0

    /// Called after `contents` or `style` changed.
    var onChange: (() -> Void)?

    init(
        mode: Mode,
        anchorRect: CGRect,
        pageLabel: String,
        excerpt: String?,
        contents: String,
        style: NoteStickerStyle
    ) {
        self.mode = mode
        self.anchorRect = anchorRect
        self.pageLabel = pageLabel
        self.excerpt = excerpt
        self.initialContents = contents
        self.initialStyle = style
        self.contents = contents
        self.style = style
    }

    /// Compatibility initializer for paper-only callers.
    convenience init(
        mode: Mode,
        anchorRect: CGRect,
        pageLabel: String,
        excerpt: String?,
        contents: String,
        paper: NotePaperColor
    ) {
        self.init(
            mode: mode,
            anchorRect: anchorRect,
            pageLabel: pageLabel,
            excerpt: excerpt,
            contents: contents,
            style: Self.resolvedStyle(for: mode, paper: paper)
        )
    }

    /// Resolves a paper-only request without discarding an existing motif.
    ///
    /// A new note starts on Simple Paper; editing a sticker note through an old
    /// paper-only call keeps the sticker it already has.
    static func resolvedStyle(for mode: Mode, paper: NotePaperColor) -> NoteStickerStyle {
        switch mode {
        case .create:
            return NoteStickerStyle(motif: .plain, palette: paper)
        case let .edit(note):
            return NoteStickerStyle(
                motif: NoteService.style(of: note.annotation).motif,
                palette: paper
            )
        }
    }

    public var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    /// Whether the user has typed or restyled anything worth protecting.
    ///
    /// Whitespace-only body edits do not count: discarding them loses nothing,
    /// and asking about them would train the user to dismiss the prompt. A
    /// motif or palette change always counts.
    public var hasUncommittedChanges: Bool {
        Self.normalized(contents) != Self.normalized(initialContents)
            || style != initialStyle
    }

    // MARK: - Committing

    /// Writes the draft into the document.
    ///
    /// Nothing is written when the target has gone away — the annotation object
    /// belongs to a document that may no longer be on screen — so the caller
    /// keeps the text and reports the failure instead of silently redirecting it
    /// to some other note.
    public func commit(to model: PDFDocumentModel) -> Result<NoteSelection, NoteEditError> {
        switch mode {
        case let .create(draft):
            return model.addNote(draft, contents: contents, style: style)
        case let .edit(note):
            return model.updateNote(note, contents: contents, style: style)
        }
    }

    /// Whether Save can do anything right now.
    public func status(in model: PDFDocumentModel) -> NoteDraftStatus {
        switch mode {
        case let .create(draft):
            guard model.isCurrent(draft) else { return .documentReplaced }
            return model.canCreateNote ? .ready : .commentingDisabled
        case let .edit(note):
            return model.isAttached(note) ? .ready : .noteRemoved
        }
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func noteChanged() {
        onChange?()
    }
}

// MARK: - Store

/// The window's one composer, and the draft that outlives its popover.
///
/// Presentation and content are separate values on purpose. A popover is
/// dismissed by any click outside it, and SwiftUI clears an `item`/`isPresented`
/// binding when that happens; if the draft lived behind that binding it would be
/// destroyed by a click. `isPresented` can therefore become false while
/// `session` — and the text in it — stays exactly where it was.
@MainActor
public final class NoteComposerStore: ObservableObject {

    @Published public private(set) var session: NoteComposerSession?

    /// Whether the popover is on screen. Not a proxy for "there is a draft".
    @Published public var isPresented: Bool = false

    /// Monotonic version of the draft. See `UnsavedWork`.
    @Published public private(set) var revision: Int = 0

    public init() {}

    public var hasSession: Bool { session != nil }

    public var hasUncommittedChanges: Bool { session?.hasUncommittedChanges ?? false }

    // MARK: - Lifecycle

    /// Opens a composer for `mode`.
    ///
    /// Refuses to replace a draft that holds unsaved text: the caller has to
    /// resolve that draft first. Returns whether the composer was opened.
    @discardableResult
    public func begin(
        mode: NoteComposerSession.Mode,
        anchorRect: CGRect,
        pageLabel: String,
        excerpt: String?,
        contents: String,
        style: NoteStickerStyle
    ) -> Bool {
        if let session, session.hasUncommittedChanges { return false }

        let session = NoteComposerSession(
            mode: mode,
            anchorRect: anchorRect,
            pageLabel: pageLabel,
            excerpt: excerpt,
            contents: contents,
            style: style
        )
        session.onChange = { [weak self] in self?.draftChanged() }
        self.session = session
        isPresented = true
        bumpRevision(on: session)
        return true
    }

    /// Compatibility entry point for paper-only callers.
    @discardableResult
    public func begin(
        mode: NoteComposerSession.Mode,
        anchorRect: CGRect,
        pageLabel: String,
        excerpt: String?,
        contents: String,
        paper: NotePaperColor
    ) -> Bool {
        begin(
            mode: mode,
            anchorRect: anchorRect,
            pageLabel: pageLabel,
            excerpt: excerpt,
            contents: contents,
            style: NoteComposerSession.resolvedStyle(for: mode, paper: paper)
        )
    }

    /// Drops the draft without writing anything.
    ///
    /// This is Cancel: no annotation is added, no `/Contents` is rewritten, no
    /// Undo entry appears and the document stays as clean as it was.
    public func end() {
        isPresented = false
        guard session != nil else { return }
        session?.onChange = nil
        session = nil
        // The draft is gone, so an approval recorded while it existed must not
        // still describe this window.
        bumpRevision(on: nil)
    }

    /// Hides the popover without touching the draft.
    ///
    /// Used when a prompt needs the window, and when the user clicks outside.
    public func closePopover() {
        isPresented = false
    }

    /// Drops a draft that has nothing worth keeping.
    public func discardIfClean() {
        guard let session, !session.hasUncommittedChanges else { return }
        end()
    }

    /// Closes a composer whose note no longer exists — unless it holds text.
    ///
    /// This is the whole rule for "another annotation edit happened": a dirty
    /// draft is never closed behind the user's back, it is left open so the
    /// composer can explain that the note is gone and offer the text back.
    public func reconcile(with model: PDFDocumentModel) {
        guard let session,
              !session.hasUncommittedChanges,
              !session.status(in: model).isReady
        else { return }
        end()
    }

    // MARK: - Committing

    /// Commits the draft and closes the composer on success.
    ///
    /// On failure the session — and every character in it — stays exactly as it
    /// was, so the caller can report the problem without losing the draft.
    @discardableResult
    public func commit(using model: PDFDocumentModel) -> Result<NoteSelection, NoteEditError> {
        guard let session else { return .failure(.noDocument) }
        let result = session.commit(to: model)
        if case .success = result { end() }
        return result
    }

    // MARK: - Revision

    private func draftChanged() {
        guard let session else { return }
        bumpRevision(on: session)
    }

    private func bumpRevision(on session: NoteComposerSession?) {
        revision &+= 1
        session?.revision = revision
    }
}

// MARK: - Prompt policy

/// An action the reader was asked to perform.
///
/// Only the reader's own vocabulary: this is the input to the decision below,
/// not a description of how the action is carried out.
public enum ReaderAction: Equatable, Sendable {
    case open(URL)
    case save
    case saveAs
    case closeWindow
    case quit
    /// Replacing the open composer with another note.
    case compose
}

/// What the reader has to ask before it may run an action.
public enum ReaderPrompt: Equatable, Sendable {
    /// Run the action now.
    case none
    /// Ask about the note that is not in the document yet.
    case draft
    /// Ask about the document's unsaved changes.
    case document
}

/// The order in which the reader asks, kept out of the view so the sequence can
/// be tested without a window.
///
/// The draft always comes first. It is the only thing that no other prompt can
/// rescue: a document save would write the PDF without it, and an open would
/// replace the document it was anchored to.
public enum ReaderPromptPolicy {

    public static func prompt(
        for action: ReaderAction,
        draftHasChanges: Bool,
        documentHasChanges: Bool
    ) -> ReaderPrompt {
        if draftHasChanges { return .draft }
        return promptAfterDraft(for: action, documentHasChanges: documentHasChanges)
    }

    /// What is left to ask once the draft has been saved or discarded.
    ///
    /// Saving the note makes the document dirty, so the action that was
    /// interrupted still has to go through the ordinary unsaved-changes prompt.
    /// Saving the document itself needs no second question — that is what the
    /// user just asked for.
    public static func promptAfterDraft(
        for action: ReaderAction,
        documentHasChanges: Bool
    ) -> ReaderPrompt {
        switch action {
        case .open, .closeWindow, .quit:
            return documentHasChanges ? .document : .none
        case .save, .saveAs, .compose:
            return .none
        }
    }
}
