import AppKit
import Foundation
import PDFKit

/// Owns one opened PDF document and the reader's navigation/zoom state.
///
/// Deliberately free of UI and of any network, account, or agent concern:
/// the model can be exercised in unit tests without a window or a running app.
@MainActor
public final class PDFDocumentModel: ObservableObject {

    public enum LoadError: Error, Equatable {
        case notAFileURL
        case unsupportedType(String)
        case fileMissing
        case permissionDenied
        case unreadable
        case emptyDocument
        case couldNotRelinkRecentDocument
        case unsupportedFileSituation(UnsupportedFileSituation)
        /// The current document has edits that are not on disk. Replacing it
        /// would discard them, so the caller has to save or discard first.
        case unsavedChanges
    }

    public static let minimumZoomScale: CGFloat = 0.25
    public static let maximumZoomScale: CGFloat = 5.0

    private static let zoomStep: CGFloat = 1.25

    @Published public private(set) var document: PDFDocument?
    @Published public private(set) var fileURL: URL?
    @Published public private(set) var title: String = ""
    @Published public private(set) var pageCount: Int = 0
    @Published public private(set) var currentPageIndex: Int = 0
    /// The zoom the user asked for. Only meaningful while `isAutoScaling` is false.
    @Published public private(set) var zoomScale: CGFloat = 1
    /// What the view is actually showing. Mirrored from PDFView so that the
    /// first manual zoom starts from the fitted scale instead of jumping to 100%.
    @Published public private(set) var effectiveScale: CGFloat = 1
    @Published public private(set) var isAutoScaling: Bool = true
    /// Changes only when the user explicitly requests a zoom or fit command.
    /// The PDFView bridge uses this to distinguish commands from scale values
    /// mirrored back while PDFKit is handling a native trackpad gesture.
    @Published public private(set) var zoomCommandRevision = 0
    @Published public private(set) var lastError: LoadError?
    /// Bumped on every successful open so the view can re-apply layout.
    @Published public private(set) var loadGeneration: Int = 0

    /// True while the in-memory document holds changes the file does not.
    ///
    /// Only annotation edits set this in P2a. It exists so that closing,
    /// switching documents or quitting cannot silently drop them; it is not a
    /// general document-modification flag yet.
    @Published public private(set) var hasUnsavedChanges: Bool = false
    /// State of the most recent automatic save for the current document.
    @Published public internal(set) var autoSaveStatus: AutoSaveStatus = .idle
    /// Bumped when an automatic save needs to be surfaced to the reader UI.
    @Published public internal(set) var autoSaveFailureRevision = 0
    /// The most recent automatic-save result, when one has completed.
    public internal(set) var lastAutoSaveOutcome: SaveOutcome?
    /// Monotonic revision of the in-memory edits.
    ///
    /// Bumped whenever edits are made, saved, discarded, or replaced by another
    /// document. A quit approval records the revision it was given for, so a
    /// later edit cannot inherit an earlier "Don't Save".
    public private(set) var editRevision: Int = 0
    /// The reader's current text selection, mirrored from `PDFView`.
    ///
    /// Owned by the model so that the Highlight button, the menu command and
    /// the annotation call all read the same value.
    @Published public private(set) var currentSelection: PDFSelection?
    /// The markup annotation the user last clicked, if any.
    ///
    /// The selection is only a UI concept. Every mutation revalidates that the
    /// annotation is still attached to the current document, so a menu opened
    /// before a document switch cannot edit the old PDF.
    @Published public internal(set) var selectedMarkup: MarkupSelection?
    /// Bumped whenever annotations are added, removed, recoloured or replaced.
    /// The PDF view uses it to tell PDFKit to redraw the affected pages.
    @Published public internal(set) var annotationRevision = 0
    /// Pages affected by the latest `annotationRevision`, sorted.
    public internal(set) var changedAnnotationPageIndices: [Int] = []
    /// The note markers the page overlays draw.
    ///
    /// Derived from the document rather than stored separately: a marker exists
    /// exactly when a visible standard `/Text` annotation exists. Recomputed
    /// after every annotation edit and after the document is replaced, so a
    /// marker cannot outlive its annotation.
    @Published public internal(set) var noteMarkers: [NoteMarker] = []
    /// Whether the current document has an undoable markup edit.
    @Published public internal(set) var canUndoMarkup = false
    @Published public internal(set) var canRedoMarkup = false

    /// PDFKit memory-maps the file, so a security-scoped URL must stay open for
    /// as long as the document is displayed. The session is the single owner of
    /// that access; the model never starts or stops a scope itself, which is
    /// what keeps the two layers from releasing each other's grants.
    ///
    /// A candidate session is replaced only after its document has been fully
    /// loaded, so a failed open leaves the previous document and its access
    /// intact.
    ///
    /// Internal rather than private so the editing extension can reuse the
    /// store when a Save As leaves a file on disk without a session.
    let store: DocumentStore

    /// App-level local history shared by reader windows. Tests and callers that
    /// do not need persistence can leave this nil.
    private let recentDocuments: RecentDocumentsStore?

    /// The persisted colour defaults. Owned by the model so the toolbar and the
    /// annotations created from it read one value, and so tests can point it at
    /// an isolated `UserDefaults` suite.
    let markupPreferences: MarkupColorPreferences

    /// Model-owned undo history.
    ///
    /// Not `UndoManager`: a cross-page mark is one action here, and the history
    /// can be cleared at exactly the moments the document is replaced. The model
    /// also owns edit semantics, so a menu action and a context-menu action use
    /// the same path.
    var markupUndoStack: [MarkupEdit] = []
    var markupRedoStack: [MarkupEdit] = []

    /// A single cancellable debounce task covers every annotation mutation.
    var autoSaveTask: Task<Void, Never>?
    var autoSaveGeneration = 0
    /// The current snapshot writer, which may outlive its debounce task after a
    /// later edit reschedules the next automatic checkpoint.
    var autoSaveWorkTask: Task<SaveOutcome, Never>?
    var autoSaveWorkGeneration: Int?
    var autoSaveWorkCompletion: AutoSaveWorkCompletion?
    /// Nested modal workflows can pause a pending debounce and resume it once
    /// the panel is dismissed. In-flight writes are allowed to finish.
    var autoSavePauseDepth = 0
    var autoSaveShouldResumeAfterPause = false
    /// The production delay is 750 ms. Tests shorten it to cover debounce
    /// scheduling without paying the user-facing interval for each scenario.
    var autoSaveDebounceNanoseconds: UInt64 = 750_000_000
    /// Injectable so the test suite can hold snapshot serialization while
    /// checking that the main actor remains responsive.
    var autoSaveSerializer: @Sendable (PDFDocumentSaveSnapshot) -> Data? = {
        PDFDocumentSaveSerializer.dataRepresentationPreservingShuaGroups(in: $0.document)
    }

    /// The open file session, or nil when nothing is loaded. Exposed so later
    /// phases can save through the same session that owns the access.
    public private(set) var documentSession: DocumentSession?

    public init(
        access: any SecurityScopeAccessing = SystemSecurityScopeAccess(),
        io: any DocumentStoreIO = SystemDocumentStoreIO(),
        markupPreferences: MarkupColorPreferences = MarkupColorPreferences(),
        recentDocuments: RecentDocumentsStore? = nil
    ) {
        self.store = DocumentStore(access: access, io: io)
        self.markupPreferences = markupPreferences
        self.recentDocuments = recentDocuments
    }

    public var isLoaded: Bool { document != nil }

    /// 1-based page number for display; 0 when nothing is open.
    public var displayPageNumber: Int { pageCount == 0 ? 0 : currentPageIndex + 1 }

    // MARK: - Opening

    /// Opens a local PDF with a two-phase switch:
    ///
    /// 1. acquire access for the candidate URL,
    /// 2. validate and load the document while that access is held,
    /// 3. only on success replace the current document and release the previous
    ///    access.
    ///
    /// A failed open therefore leaves the loaded document *and* its security
    /// scope untouched. Returns `false` and records `lastError` on failure.
    ///
    /// A document with unsaved edits is refused with `.unsavedChanges` instead
    /// of being replaced: dropping the edits is a decision the user makes, not
    /// a side effect of opening a file. The caller saves or discards first.
    ///
    /// `discardingUnsavedChanges` is that decision, but it is **not** taken on
    /// trust: the edits are only abandoned as part of the commit in phase 3, so
    /// an open that fails still leaves the previous document, its annotations
    /// and its dirty state exactly as they were. Discarding before the new
    /// document is known to be readable would clear the flag on a document that
    /// is still on screen, and the next close would drop its edits without
    /// asking.
    ///
    /// When `relinking` is supplied, the saved recent entry is updated only
    /// after the selected PDF and its security-scoped session have both opened
    /// successfully. A failed candidate leaves that entry intact.
    @discardableResult
    public func open(
        url: URL,
        discardingUnsavedChanges: Bool = false,
        relinking recentDocument: RecentDocument? = nil
    ) -> Bool {
        guard discardingUnsavedChanges || !hasUnsavedChanges else {
            lastError = .unsavedChanges
            return false
        }
        guard url.isFileURL else {
            lastError = .notAFileURL
            return false
        }
        guard url.pathExtension.lowercased() == "pdf" else {
            lastError = .unsupportedType(url.pathExtension)
            return false
        }

        let restoredPosition: RecentReadingPosition?
        if let recentDocument {
            restoredPosition = recentDocuments?.readingPosition(for: recentDocument)
                ?? recentDocument.readingPosition
        } else {
            restoredPosition = recentDocuments?.readingPosition(for: url)
        }

        let reopeningCurrentFile = fileURL?.standardizedFileURL == url.standardizedFileURL
        if reopeningCurrentFile {
            pauseAutoSave()
        }
        defer {
            if reopeningCurrentFile {
                resumeAutoSave()
            }
        }

        // Phase 1: acquire access and record the initial version. The store
        // acquires the scope before touching the file: a security-scoped URL
        // must be opened before any access, including an existence check,
        // because in a sandboxed build `fileExists` on an unopened URL can
        // fail even when the file is there.
        var candidate: DocumentSession
        do {
            candidate = try store.open(url)
        } catch let error as DocumentStoreError {
            lastError = Self.loadError(from: error)
            return false
        } catch {
            lastError = .unreadable
            return false
        }

        // Phase 2: validate while the candidate access is still active.
        guard var opened = PDFDocument(url: url) else {
            candidate.close()
            lastError = .unreadable
            return false
        }
        guard opened.pageCount > 0 else {
            candidate.close()
            lastError = .emptyDocument
            return false
        }

        // Phase 3: commit. Stop a pending checkpoint before discarding the
        // previous document, then release its scope only after any already
        // running file operation has ended.
        let hadPendingAutoSave = autoSaveStatus == .pending && autoSaveTask != nil
        cancelPendingAutoSave(cancelInFlightWork: discardingUnsavedChanges)
        let automaticWriteWasStarted = autoSaveWorkCompletion?.didStartWrite ?? false
        waitForAutoSaveWork()

        // If the old worker committed while the candidate was being loaded,
        // that candidate and its session captured the previous file version.
        // Reopen both after the worker has stopped so the installed document
        // and session always describe the same bytes.
        if reopeningCurrentFile, automaticWriteWasStarted {
            candidate.close()
            do {
                candidate = try store.open(url)
            } catch let error as DocumentStoreError {
                lastError = Self.loadError(from: error)
                return false
            } catch {
                lastError = .unreadable
                return false
            }

            guard let refreshed = PDFDocument(url: url) else {
                candidate.close()
                lastError = .unreadable
                return false
            }
            guard refreshed.pageCount > 0 else {
                candidate.close()
                lastError = .emptyDocument
                return false
            }
            opened = refreshed
        }

        if let recentDocument {
            do {
                guard let recentDocuments,
                      try recentDocuments.relink(recentDocument, to: url)
                else {
                    candidate.close()
                    restoreAutoSaveAfterFailedOpen(wasPending: hadPendingAutoSave)
                    lastError = .couldNotRelinkRecentDocument
                    return false
                }
            } catch {
                candidate.close()
                restoreAutoSaveAfterFailedOpen(wasPending: hadPendingAutoSave)
                lastError = .couldNotRelinkRecentDocument
                return false
            }
        }

        // Swap first, then release the previous scope, so the
        // model is never left without access to the document it displays.
        let previous = documentSession
        documentSession = candidate
        previous?.close()

        apply(document: opened, fileURL: url, restoring: restoredPosition)
        if recentDocument == nil, let recentDocuments, !recentDocuments.recordOpened(url) {
            NSLog("YoPDF could not save a recent-document bookmark for %@", url.lastPathComponent)
        }
        persistReadingPosition()
        return true
    }

    public func close() {
        persistReadingPosition()
        cancelPendingAutoSave(cancelInFlightWork: true)
        waitForAutoSaveWork()
        autoSavePauseDepth = 0
        autoSaveShouldResumeAfterPause = false
        documentSession?.close()
        documentSession = nil
        document = nil
        fileURL = nil
        title = ""
        pageCount = 0
        currentPageIndex = 0
        zoomScale = 1
        effectiveScale = 1
        isAutoScaling = true
        lastError = nil
        hasUnsavedChanges = false
        autoSaveStatus = .idle
        lastAutoSaveOutcome = nil
        editRevision &+= 1
        currentSelection = nil
        resetMarkupState()
        noteMarkers = []
        loadGeneration &+= 1
    }

    public func dismissError() {
        lastError = nil
    }

    private func apply(
        document: PDFDocument,
        fileURL: URL?,
        restoring position: RecentReadingPosition?
    ) {
        cancelPendingAutoSave()
        self.document = document
        self.fileURL = fileURL
        pageCount = document.pageCount
        currentPageIndex = Self.clamped(position?.pageIndex ?? 0, pageCount: document.pageCount)
        let restoredZoom = CGFloat(position?.zoomScale ?? 1)
        zoomScale = restoredZoom.isFinite
            ? min(max(restoredZoom, Self.minimumZoomScale), Self.maximumZoomScale)
            : 1
        effectiveScale = zoomScale
        isAutoScaling = position?.usesAutomaticScaling ?? true
        lastError = nil
        hasUnsavedChanges = false
        autoSaveStatus = .idle
        lastAutoSaveOutcome = nil
        editRevision &+= 1
        currentSelection = nil
        resetMarkupState()
        refreshNoteMarkers()
        title = Self.resolvedTitle(for: document, fileURL: fileURL)
        loadGeneration &+= 1
    }

    // MARK: - Editing support

    /// Where the reader is, so that replacing the in-memory document does not
    /// send the user back to page one.
    struct ReadingPosition {
        let pageIndex: Int
        let zoomScale: CGFloat
        let effectiveScale: CGFloat
        let isAutoScaling: Bool
    }

    var readingPosition: ReadingPosition {
        ReadingPosition(
            pageIndex: currentPageIndex,
            zoomScale: zoomScale,
            effectiveScale: effectiveScale,
            isAutoScaling: isAutoScaling
        )
    }

    /// Replaces the displayed document without touching the navigation state
    /// the user chose.
    ///
    /// Deliberately does **not** bump `loadGeneration`: the view keeps its
    /// `PDFView` and re-attaches the new document, so scroll position within the
    /// page survives a save. Bumping the generation would rebuild the view and
    /// jump back to the top of the page.
    func swapDocument(_ newDocument: PDFDocument, at position: ReadingPosition) {
        document = newDocument
        pageCount = newDocument.pageCount
        currentPageIndex = Self.clamped(position.pageIndex, pageCount: newDocument.pageCount)
        zoomScale = position.zoomScale
        effectiveScale = position.effectiveScale
        isAutoScaling = position.isAutoScaling
        currentSelection = nil
        resetMarkupState()
        changedAnnotationPageIndices = Array(0..<newDocument.pageCount)
        annotationRevision &+= 1
        refreshNoteMarkers()
        title = Self.resolvedTitle(for: newDocument, fileURL: fileURL)
    }

    /// Points the model at a new file, used by Save As.
    func adoptFileLocation(_ url: URL) {
        fileURL = url
        if let document {
            title = Self.resolvedTitle(for: document, fileURL: url)
        }
        if let recentDocuments, !recentDocuments.recordOpened(url) {
            NSLog("YoPDF could not save a recent-document bookmark for %@", url.lastPathComponent)
        }
        persistReadingPosition()
    }

    /// Swaps in the session that now owns the file, closing the old one.
    ///
    /// Used after Save As: the new session already holds the destination's
    /// access, and the previous file must stop being held.
    func adoptSession(_ session: DocumentSession?) {
        let previous = documentSession
        documentSession = session
        if previous !== session {
            previous?.close()
        }
    }

    func markEdited() {
        hasUnsavedChanges = true
        editRevision &+= 1
        scheduleAutoSave()
    }

    func markSaved(preservingMarkupHistory: Bool = false) {
        cancelPendingAutoSave()
        hasUnsavedChanges = false
        autoSaveStatus = .idle
        lastAutoSaveOutcome = nil
        editRevision &+= 1
        // Manual saves replace the PDFDocument below and therefore clear its
        // annotation-object history. Automatic saves keep the live document,
        // so the same entries can still undo and redo edits after persistence.
        if !preservingMarkupHistory {
            resetMarkupState()
        }
    }

    /// Clears every reference to the annotations of the document being replaced.
    ///
    /// The undo entries hold `PDFAnnotation` objects, and an annotation belongs
    /// to the `PDFDocument` that created it. Keeping them after an open, close,
    /// manual save reload or Save As would leave a menu action able to mutate
    /// an old in-memory document that is no longer on screen. Auto-save retains
    /// the live document and can safely preserve the history.
    func resetMarkupState() {
        markupUndoStack.removeAll()
        markupRedoStack.removeAll()
        canUndoMarkup = false
        canRedoMarkup = false
        selectedMarkup = nil
        changedAnnotationPageIndices = []
    }

    /// Mirrors the view's selection into the model.
    ///
    /// The view is the only writer: it reports what `PDFView` selected, and
    /// reports `nil` after the model cleared it (a highlight consumed it).
    public func updateSelection(_ selection: PDFSelection?) {
        guard selection !== currentSelection else { return }
        currentSelection = selection
        // A real text selection starts a new intent. Clearing the annotation
        // controls here also covers a drag that begins over a mark: the mark is
        // only selected by a click that did not drag.
        if let selection,
           !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selectedMarkup = nil
        }
    }

    private static func clamped(_ index: Int, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        return min(max(index, 0), pageCount - 1)
    }

    private static func resolvedTitle(for document: PDFDocument, fileURL: URL?) -> String {
        if let raw = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let name = fileURL?.deletingPathExtension().lastPathComponent, !name.isEmpty {
            return name
        }
        return "Untitled"
    }

    /// Keeps the reader's user-facing failures narrow while the store reports
    /// the file-level situation precisely.
    private static func loadError(from error: DocumentStoreError) -> LoadError {
        switch error {
        case .notAFileURL:
            return .notAFileURL
        case .fileMissing:
            return .fileMissing
        case .permissionDenied, .readOnly:
            return .permissionDenied
        case let .unsupportedFileSituation(situation, _):
            return .unsupportedFileSituation(situation)
        case .notReadable, .sessionClosed, .externalModificationDetected,
             .targetExists, .stagingFailed, .replacementFailed,
             .replacementStateUncertain, .committedButUnverified,
             .sessionNeedsRefresh, .reloadRequired, .targetAppearedDuringSave,
             .coordinationFailed:
            // None of these can happen while opening a file; they are save- and
            // session-level outcomes. Kept here so the mapping stays exhaustive.
            return .unreadable
        }
    }

    // MARK: - Navigation

    public func goToPage(_ index: Int) {
        guard pageCount > 0 else { return }
        let clampedIndex = min(max(index, 0), pageCount - 1)
        guard clampedIndex != currentPageIndex else { return }
        currentPageIndex = clampedIndex
        persistReadingPosition()
    }

    public func goToNextPage() {
        goToPage(currentPageIndex + 1)
    }

    public func goToPreviousPage() {
        goToPage(currentPageIndex - 1)
    }

    // MARK: - Zoom

    public func setZoomScale(_ scale: CGFloat) {
        guard scale.isFinite else { return }
        zoomScale = min(max(scale, Self.minimumZoomScale), Self.maximumZoomScale)
        effectiveScale = zoomScale
        isAutoScaling = false
        zoomCommandRevision &+= 1
        persistReadingPosition()
    }

    /// Base for the next zoom step: the live fitted scale while auto-scaling,
    /// otherwise the user's chosen scale.
    private var zoomBase: CGFloat {
        isAutoScaling ? effectiveScale : zoomScale
    }

    public func zoomIn() {
        setZoomScale(zoomBase * Self.zoomStep)
    }

    public func zoomOut() {
        setZoomScale(zoomBase / Self.zoomStep)
    }

    public func resetZoom() {
        setZoomScale(1)
    }

    public func fitToWindow() {
        isAutoScaling = true
        zoomCommandRevision &+= 1
        persistReadingPosition()
    }

    /// Called by the view whenever PDFView's scale changes. Never flips
    /// `isAutoScaling`: the view is the only source of truth while fitting.
    public func updateEffectiveScale(_ scale: CGFloat) {
        guard scale.isFinite, scale > 0 else { return }
        effectiveScale = scale
        if !isAutoScaling {
            zoomScale = min(max(scale, Self.minimumZoomScale), Self.maximumZoomScale)
            persistReadingPosition()
        }
    }

    public func setAutoScaling(_ enabled: Bool) {
        if enabled {
            fitToWindow()
        } else {
            // PDFKit already owns the live PDFView scale during a magnify
            // gesture. Record that manual zoom has started without sending a
            // scale command back through NSViewRepresentable.updateNSView.
            isAutoScaling = false
            zoomScale = min(max(effectiveScale, Self.minimumZoomScale), Self.maximumZoomScale)
            persistReadingPosition()
        }
    }

    private func persistReadingPosition() {
        guard let url = fileURL else { return }
        recentDocuments?.updateReadingPosition(
            RecentReadingPosition(
                pageIndex: currentPageIndex,
                zoomScale: Double(zoomScale),
                usesAutomaticScaling: isAutoScaling
            ),
            for: url
        )
    }
}

extension PDFDocumentModel.LoadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAFileURL:
            return "That location is not a local file."
        case let .unsupportedType(ext):
            let suffix = ext.isEmpty ? "no file extension" : ".\(ext)"
            return "YoPDF can only open PDF files, but this file has \(suffix)."
        case .fileMissing:
            return "The file could not be found. It may have been moved or deleted."
        case .permissionDenied:
            return "YoPDF does not have permission to open this file."
        case .unreadable:
            return "This file is not a readable PDF. It may be damaged or password protected."
        case .emptyDocument:
            return "This PDF contains no pages."
        case .couldNotRelinkRecentDocument:
            return "YoPDF could not relink this recent document. The existing recent entry was left unchanged."
        case .unsavedChanges:
            return "Save or discard your changes before opening another document."
        case let .unsupportedFileSituation(situation):
            switch situation {
            case .symbolicLink:
                return "This PDF is a symbolic link. Open the file it points to instead."
            case let .hardLink(count):
                return "This PDF is linked to \(count) other files and cannot be opened safely."
            case .notARegularFile:
                return "That location is not a regular file."
            case .cloudPlaceholderNotDownloaded:
                return "This PDF has not been downloaded from the cloud yet."
            case .sameFileAsCurrent:
                return "That is the file that is already open."
            }
        }
    }
}
