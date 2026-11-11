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

/// Protocol for resolving a page-space rectangle to container/view coordinates.
@MainActor
public protocol PageAnchorResolving: AnyObject {
    func containerRect(forPageBounds bounds: CGRect, pageIndex: Int) -> CGRect?
}

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

    /// A point-in-time draft used when the user opens the expanded editor.
    ///
    /// The expanded editor writes through to this session so every edit is
    /// revisioned and protected. Cancel restores this snapshot, including the
    /// template seed, without committing anything to the PDF.
    public struct Snapshot: Equatable, Sendable {
        public let contents: String
        public let style: NoteStickerStyle
        public let templateSelection: NoteTemplateSelection

        public init(
            contents: String,
            style: NoteStickerStyle,
            templateSelection: NoteTemplateSelection
        ) {
            self.contents = contents
            self.style = style
            self.templateSelection = templateSelection
        }
    }

    /// What Save means: adding a note at a captured anchor, or changing one that
    /// is already in the document.
    public enum Mode {
        case create(NoteDraft)
        case edit(NoteSelection)
        /// Adds a new entry to an existing YoPDF or ShuaMac note thread.
        case group(NoteSelection)
    }

    public let id = UUID()
    public let mode: Mode
    /// Where the popover's arrow points, in the reader's top-left space.
    ///
    /// The persistent logical anchor (`logicalPageIndex`, `logicalBounds`) is authoritative.
    /// This presentation rectangle is transient and should be recalculated via `PageAnchorResolving`
    /// whenever the pane is resized, split, or reparented.
    @Published public internal(set) var anchorRect: CGRect
    public let pageLabel: String
    public let excerpt: String?

    public var logicalPageIndex: Int {
        switch mode {
        case let .create(draft):
            return draft.pageIndex
        case let .edit(note), let .group(note):
            return note.pageIndex
        }
    }

    public var logicalBounds: CGRect {
        switch mode {
        case let .create(draft):
            return draft.bounds
        case let .edit(note), let .group(note):
            return note.bounds
        }
    }

    /// Stable runtime identity of the annotation being edited or grouped, if any.
    ///
    /// PDFKit annotations do not possess persistent UUIDs in memory unless serialized
    /// with YoPDF / Shua metadata. `ObjectIdentifier` provides runtime object identity.
    public var targetAnnotationID: ObjectIdentifier? {
        switch mode {
        case .create:
            return nil
        case let .edit(note), let .group(note):
            return note.id
        }
    }

    /// Persistent UUID of the annotation when backed by Shua or YoPDF thread metadata.
    public var targetAnnotationUUID: UUID? {
        switch mode {
        case .create:
            return nil
        case let .edit(note), let .group(note):
            return NoteService.shuaAnchorID(of: note.annotation)
                ?? NoteService.yoPDFThreadID(of: note.annotation)
        }
    }

    /// Transitional presentation anchor update.
    public func updatePresentationAnchorRect(_ newRect: CGRect) {
        self.anchorRect = newRect
    }

    @discardableResult
    public func updatePresentationAnchor(using resolver: PageAnchorResolving) -> Bool {
        guard let rect = resolver.containerRect(forPageBounds: logicalBounds, pageIndex: logicalPageIndex) else {
            return false
        }
        self.anchorRect = rect
        return true
    }
    /// What the draft looked like when the composer opened. `hasUncommittedChanges`
    /// is measured against these, not against the document.
    public private(set) var initialContents: String
    public private(set) var initialStyle: NoteStickerStyle

    /// Kept for PR #6 callers/tests: the paper is part of the style now.
    public var initialPaper: NotePaperColor { initialStyle.palette }

    @Published public var contents: String {
        didSet {
            if contents.isEmpty { templateSelection.reset() }
            noteChanged()
        }
    }

    /// The complete appearance being edited. Motif, palette, title and symbol
    /// are one value so a single revision bump covers any change.
    @Published public var style: NoteStickerStyle {
        didSet { noteChanged() }
    }

    /// Which template outline the editor currently owns.
    ///
    /// Held outside the appearance popover so closing and reopening the popover
    /// cannot forget that an untouched outline came from a template. Changes to
    /// the seed alone are not document edits and do not bump the draft revision.
    public var templateSelection = NoteTemplateSelection()

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
    /// A new note starts on ShuaMac's default sticker; editing a sticker note
    /// through an old paper-only call keeps the sticker it already has.
    static func resolvedStyle(for mode: Mode, paper: NotePaperColor) -> NoteStickerStyle {
        switch mode {
        case .create:
            return NoteStickerStyle(motif: NoteStickerStyle.newNote.motif, palette: paper)
        case let .edit(note):
            return NoteStickerStyle(
                motif: NoteService.style(of: note.annotation).motif,
                palette: paper
            )
        case let .group(note):
            return NoteService.style(of: note.annotation)
        }
    }

    public var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    public var isGroupComposer: Bool {
        if case .group = mode { return true }
        return false
    }

    /// Clears the just-saved entry while keeping the thread composer open for
    /// another note. The chosen sticker style becomes the next entry's draft
    /// baseline, so closing the popover does not report a committed style as
    /// unsaved work.
    public func prepareNextGroupEntry() {
        guard isGroupComposer else { return }
        contents = ""
        initialContents = ""
        initialStyle = style
    }

    /// Whether the draft has a body at all.
    ///
    /// Every note edit refuses an empty body, so a composer with blank text
    /// cannot be written no matter what it looks like. It is not "a note that
    /// has not been saved yet": there is no note, only an appearance choice.
    public var hasEmptyContents: Bool {
        Self.normalized(contents).isEmpty
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

    /// Captures the current values before entering the expanded editor.
    public func snapshot() -> Snapshot {
        Snapshot(
            contents: contents,
            style: style,
            templateSelection: templateSelection
        )
    }

    /// Restores the values that were present when the expanded editor opened.
    /// The published properties still advance the draft revision, ensuring any
    /// close or quit approval made during editing cannot apply to a later state.
    public func restore(from snapshot: Snapshot) {
        contents = snapshot.contents
        style = snapshot.style
        templateSelection = snapshot.templateSelection
    }

    // MARK: - Committing

    /// Writes the draft into the document through a resource session.
    public func commit(to resourceSession: PDFResourceSession) -> Result<NoteSelection, NoteEditError> {
        switch mode {
        case let .create(draft):
            return resourceSession.addNote(draft, contents: contents, style: style)
        case let .edit(note):
            return resourceSession.updateNote(note, contents: contents, style: style)
        case let .group(note):
            return resourceSession.addThought(to: note, contents: contents, style: style)
        }
    }

    public func commit(to paneModel: PDFPaneModel) -> Result<NoteSelection, NoteEditError> {
        let result = commit(to: paneModel.resourceSession)
        if case .success = result {
            paneModel.updateSelection(nil)
            paneModel.clearMarkupSelection()
        }
        return result
    }

    /// Writes the draft into the document.
    ///
    /// Nothing is written when the target has gone away — the annotation object
    /// belongs to a document that may no longer be on screen — so the caller
    /// keeps the text and reports the failure instead of silently redirecting it
    /// to some other note.
    public func commit(to model: PDFDocumentModel) -> Result<NoteSelection, NoteEditError> {
        commit(to: model.paneModel)
    }

    public func status(in resourceSession: PDFResourceSession) -> NoteDraftStatus {
        switch mode {
        case let .create(draft):
            guard resourceSession.isCurrent(draft) else { return .documentReplaced }
            return resourceSession.canCreateNote ? .ready : .commentingDisabled
        case let .edit(note):
            return resourceSession.isAttached(note) ? .ready : .noteRemoved
        case let .group(note):
            guard resourceSession.isAttached(note) else { return .noteRemoved }
            return resourceSession.canCreateNote ? .ready : .commentingDisabled
        }
    }

    public func status(in paneModel: PDFPaneModel) -> NoteDraftStatus {
        status(in: paneModel.resourceSession)
    }

    /// Whether Save can do anything right now.
    public func status(in model: PDFDocumentModel) -> NoteDraftStatus {
        status(in: model.resourceSession)
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

    public func updatePresentationAnchorRect(_ newRect: CGRect) {
        session?.updatePresentationAnchorRect(newRect)
    }

    @discardableResult
    public func updatePresentationAnchor(using resolver: PageAnchorResolving) -> Bool {
        session?.updatePresentationAnchor(using: resolver) ?? false
    }

    /// Closes a composer whose note no longer exists — unless it holds text.
    public func reconcile(with resourceSession: PDFResourceSession) {
        guard let session,
              !session.hasUncommittedChanges,
              !session.status(in: resourceSession).isReady
        else { return }
        end()
    }

    public func reconcile(with paneModel: PDFPaneModel) {
        reconcile(with: paneModel.resourceSession)
    }

    /// Closes a composer whose note no longer exists — unless it holds text.
    ///
    /// This is the whole rule for "another annotation edit happened": a dirty
    /// draft is never closed behind the user's back, it is left open so the
    /// composer can explain that the note is gone and offer the text back.
    public func reconcile(with model: PDFDocumentModel) {
        reconcile(with: model.resourceSession)
    }

    // MARK: - Committing

    @discardableResult
    public func commit(using resourceSession: PDFResourceSession) -> Result<NoteSelection, NoteEditError> {
        guard let session else { return .failure(.noDocument) }
        let result = session.commit(to: resourceSession)
        if case .success = result { end() }
        return result
    }

    @discardableResult
    public func commit(using paneModel: PDFPaneModel) -> Result<NoteSelection, NoteEditError> {
        guard let session else { return .failure(.noDocument) }
        let result = session.commit(to: paneModel)
        if case .success = result { end() }
        return result
    }

    /// Commits the draft and closes the composer on success.
    ///
    /// This is the action prompt's "Save Note", not the popover's own Save: the
    /// user is leaving this draft to open a file, another note, or to quit, so
    /// even a thread composer must close. Keeping a thread composer open for
    /// another entry belongs to `NoteComposerView`, which commits through the
    /// session and calls `prepareNextGroupEntry()` itself. If a successful
    /// commit left a session behind here, the next note click could find it
    /// dirty again and ask the same question a second time.
    ///
    /// On failure the session — and every character in it — stays exactly as it
    /// was, so the caller can report the problem without losing the draft.
    @discardableResult
    public func commit(using model: PDFDocumentModel) -> Result<NoteSelection, NoteEditError> {
        commit(using: model.paneModel)
    }

    public func resolvePendingDraft(
        using resourceSession: PDFResourceSession
    ) -> Result<NoteSelection?, NoteEditError> {
        guard let session else { return .success(nil) }
        if session.hasEmptyContents {
            switch session.mode {
            case .create, .group:
                end()
                return .success(nil)
            case .edit:
                return .failure(.emptyContents)
            }
        }
        return commit(using: resourceSession).map { Optional.some($0) }
    }

    public func resolvePendingDraft(
        using paneModel: PDFPaneModel
    ) -> Result<NoteSelection?, NoteEditError> {
        guard let session else { return .success(nil) }
        if session.hasEmptyContents {
            switch session.mode {
            case .create, .group:
                end()
                return .success(nil)
            case .edit:
                return .failure(.emptyContents)
            }
        }
        return commit(using: paneModel).map { Optional.some($0) }
    }

    /// Resolves the draft an interrupted reader action is waiting on.
    ///
    /// A new note or thread entry with a blank body has nothing to write: the
    /// document refuses empty notes, so such a draft holds only an appearance
    /// choice. Ending it is the only honest answer to "Save Note" — there is no
    /// text to lose and no write to make, and trying to write it would fail and
    /// leave the draft protected forever.
    ///
    /// Clearing the body of an *existing* note is different. The edit itself is
    /// the unsaved work, and `updateNote` refuses an empty body, so dropping the
    /// draft would silently discard what the user just did. That case fails with
    /// `.emptyContents` and leaves the composer open, so the action prompt can
    /// offer "Back to Draft" or an explicit "Discard Draft".
    ///
    /// A real body is committed, and either way the composer closes on success
    /// so the interrupted action can proceed.
    ///
    /// - Returns `.success(nil)` when nothing was written, `.success(note)` when
    ///   a note was committed, or `.failure` when the draft could not be
    ///   resolved. On failure the draft stays open so the edit survives.
    public func resolvePendingDraft(
        using model: PDFDocumentModel
    ) -> Result<NoteSelection?, NoteEditError> {
        resolvePendingDraft(using: model.paneModel)
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
    case closeTab
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
        case .open, .closeTab, .closeWindow, .quit:
            return documentHasChanges ? .document : .none
        case .save, .saveAs, .compose:
            return .none
        }
    }
}
