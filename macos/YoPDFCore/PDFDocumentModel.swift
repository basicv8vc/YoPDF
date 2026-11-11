import AppKit
import Combine
import Foundation
import PDFKit

/// Owns one opened PDF document and the reader's navigation/zoom state.
///
/// Deliberately free of UI and of any network, account, or agent concern:
/// the model can be exercised in unit tests without a window or a running app.
///
/// Refactored in P0-B as a compatibility façade composing a shared `PDFResourceSession`
/// (runtime authority for the document, file lease, and undo history) and a `PDFPaneModel`
/// (pane-local viewport, zoom, selection, and search state).
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

    public let resourceSession: PDFResourceSession
    public let paneModel: PDFPaneModel

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Published Properties Forwarded to Sessions

    public var document: PDFDocument? { resourceSession.document }
    public var fileURL: URL? { resourceSession.fileURL }
    public var title: String { resourceSession.title }
    public var pageCount: Int { resourceSession.pageCount }
    public var currentPageIndex: Int { paneModel.currentPageIndex }
    /// Changes only for explicit page commands, never for PDFView feedback.
    public var pageNavigationRevision: Int { paneModel.pageNavigationRevision }
    /// The zoom the user asked for. Only meaningful while `isAutoScaling` is false.
    public var zoomScale: CGFloat { paneModel.zoomScale }
    /// What the view is actually showing. Mirrored from PDFView so that the
    /// first manual zoom starts from the fitted scale instead of jumping to 100%.
    public var effectiveScale: CGFloat { paneModel.effectiveScale }
    public var isAutoScaling: Bool { paneModel.isAutoScaling }
    /// Changes only when the user explicitly requests a zoom or fit command.
    public var zoomCommandRevision: Int { paneModel.zoomCommandRevision }
    public var lastError: LoadError? { resourceSession.lastError }
    /// Bumped on every successful open so the view can re-apply layout.
    public var loadGeneration: Int { resourceSession.loadGeneration }

    public var hasUnsavedChanges: Bool { resourceSession.hasUnsavedChanges }
    public var autoSaveStatus: AutoSaveStatus {
        get { resourceSession.autoSaveStatus }
        set { resourceSession.autoSaveStatus = newValue }
    }
    public var autoSaveFailureRevision: Int {
        get { resourceSession.autoSaveFailureRevision }
        set { resourceSession.autoSaveFailureRevision = newValue }
    }
    public var lastAutoSaveOutcome: SaveOutcome? {
        get { resourceSession.lastAutoSaveOutcome }
        set { resourceSession.lastAutoSaveOutcome = newValue }
    }
    public var editRevision: Int { resourceSession.editRevision }
    public var currentSelection: PDFSelection? { paneModel.currentSelection }
    public var selectedMarkup: MarkupSelection? {
        get { paneModel.selectedMarkup }
        set { paneModel.selectedMarkup = newValue }
    }
    public var annotationRevision: Int {
        get { resourceSession.annotationRevision }
        set { resourceSession.annotationRevision = newValue }
    }
    public var changedAnnotationPageIndices: [Int] {
        get { resourceSession.changedAnnotationPageIndices }
        set { resourceSession.changedAnnotationPageIndices = newValue }
    }
    public var noteMarkers: [NoteMarker] {
        get { resourceSession.noteMarkers }
        set { resourceSession.noteMarkers = newValue }
    }
    public var canUndoMarkup: Bool {
        get { resourceSession.canUndoMarkup }
        set { resourceSession.canUndoMarkup = newValue }
    }
    public var canRedoMarkup: Bool {
        get { resourceSession.canRedoMarkup }
        set { resourceSession.canRedoMarkup = newValue }
    }

    var store: DocumentStore { resourceSession.store }
    private var recentDocuments: RecentDocumentsStore? { resourceSession.recentDocuments }
    public var markupPreferences: MarkupColorPreferences { resourceSession.markupPreferences }

    var markupUndoStack: [MarkupEdit] {
        get { resourceSession.markupUndoStack }
        set { resourceSession.markupUndoStack = newValue }
    }
    var markupRedoStack: [MarkupEdit] {
        get { resourceSession.markupRedoStack }
        set { resourceSession.markupRedoStack = newValue }
    }

    var autoSaveTask: Task<Void, Never>? {
        get { resourceSession.autoSaveTask }
        set { resourceSession.autoSaveTask = newValue }
    }
    var autoSaveGeneration: Int {
        get { resourceSession.autoSaveGeneration }
        set { resourceSession.autoSaveGeneration = newValue }
    }
    var autoSaveWorkTask: Task<SaveOutcome, Never>? {
        get { resourceSession.autoSaveWorkTask }
        set { resourceSession.autoSaveWorkTask = newValue }
    }
    var autoSaveWorkGeneration: Int? {
        get { resourceSession.autoSaveWorkGeneration }
        set { resourceSession.autoSaveWorkGeneration = newValue }
    }
    var autoSaveWorkCompletion: AutoSaveWorkCompletion? {
        get { resourceSession.autoSaveWorkCompletion }
        set { resourceSession.autoSaveWorkCompletion = newValue }
    }
    var autoSavePauseDepth: Int {
        get { resourceSession.autoSavePauseDepth }
        set { resourceSession.autoSavePauseDepth = newValue }
    }
    var autoSaveShouldResumeAfterPause: Bool {
        get { resourceSession.autoSaveShouldResumeAfterPause }
        set { resourceSession.autoSaveShouldResumeAfterPause = newValue }
    }
    var autoSaveDebounceNanoseconds: UInt64 {
        get { resourceSession.autoSaveDebounceNanoseconds }
        set { resourceSession.autoSaveDebounceNanoseconds = newValue }
    }
    var autoSaveSerializer: @Sendable (PDFDocumentSaveSnapshot) -> Data? {
        get { resourceSession.autoSaveSerializer }
        set { resourceSession.autoSaveSerializer = newValue }
    }

    public var documentSession: DocumentSession? { resourceSession.documentSession }

    public init(
        access: any SecurityScopeAccessing = SystemSecurityScopeAccess(),
        io: any DocumentStoreIO = SystemDocumentStoreIO(),
        markupPreferences: MarkupColorPreferences = .shared,
        recentDocuments: RecentDocumentsStore? = nil
    ) {
        let resource = PDFResourceSession(
            access: access,
            io: io,
            markupPreferences: markupPreferences,
            recentDocuments: recentDocuments
        )
        self.resourceSession = resource
        self.paneModel = PDFPaneModel(resourceSession: resource)
        setupForwarding()
    }

    public init(resourceSession: PDFResourceSession, paneModel: PDFPaneModel? = nil) {
        self.resourceSession = resourceSession
        self.paneModel = paneModel ?? PDFPaneModel(resourceSession: resourceSession)
        setupForwarding()
    }

    private func setupForwarding() {
        resourceSession.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        paneModel.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    public var isLoaded: Bool { resourceSession.isLoaded }

    /// 1-based page number for display; 0 when nothing is open.
    public var displayPageNumber: Int { paneModel.displayPageNumber }

    // MARK: - Opening

    @discardableResult
    public func open(
        url: URL,
        discardingUnsavedChanges: Bool = false,
        relinking recentDocument: RecentDocument? = nil
    ) -> Bool {
        let success = resourceSession.open(
            url: url,
            discardingUnsavedChanges: discardingUnsavedChanges,
            relinking: recentDocument
        )
        if success {
            paneModel.clearSearch()
            paneModel.noteComposerStore.discardIfClean()
            let restoredPosition: RecentReadingPosition?
            if let recentDocument {
                restoredPosition = recentDocuments?.readingPosition(for: recentDocument)
                    ?? recentDocument.readingPosition
            } else {
                restoredPosition = recentDocuments?.readingPosition(for: url)
            }
            if let restoredPosition {
                paneModel.goToPage(restoredPosition.pageIndex)
                let restoredZoom = CGFloat(restoredPosition.zoomScale)
                let z = restoredZoom.isFinite ? min(max(restoredZoom, Self.minimumZoomScale), Self.maximumZoomScale) : 1
                paneModel.setZoomScale(z)
                if restoredPosition.usesAutomaticScaling {
                    paneModel.fitToWindow()
                }
            } else {
                paneModel.goToPage(0)
                paneModel.setZoomScale(1)
                paneModel.fitToWindow()
            }
            paneModel.updateSelection(nil)
        }
        return success
    }

    public func close() {
        paneModel.close()
    }

    public func dismissError() {
        resourceSession.dismissError()
    }

    // MARK: - Editing support

    struct ReadingPosition {
        let pageIndex: Int
        let zoomScale: CGFloat
        let effectiveScale: CGFloat
        let isAutoScaling: Bool
    }

    var readingPosition: ReadingPosition {
        ReadingPosition(
            pageIndex: paneModel.currentPageIndex,
            zoomScale: paneModel.zoomScale,
            effectiveScale: paneModel.effectiveScale,
            isAutoScaling: paneModel.isAutoScaling
        )
    }

    func swapDocument(_ newDocument: PDFDocument, at position: ReadingPosition) {
        resourceSession.swapDocument(newDocument)
        paneModel.goToPage(position.pageIndex)
        paneModel.setZoomScale(position.zoomScale)
        paneModel.updateEffectiveScale(position.effectiveScale)
        if position.isAutoScaling {
            paneModel.fitToWindow()
        }
    }

    func adoptFileLocation(_ url: URL) {
        resourceSession.adoptFileLocation(url)
    }

    func adoptSession(_ session: DocumentSession?) {
        resourceSession.adoptSession(session)
    }

    func markEdited() {
        resourceSession.markEdited()
    }

    func markSaved(preservingMarkupHistory: Bool = false) {
        resourceSession.markSaved(preservingMarkupHistory: preservingMarkupHistory)
        if !preservingMarkupHistory {
            paneModel.clearMarkupSelection()
        }
    }

    func resetMarkupState() {
        resourceSession.resetMarkupState()
        paneModel.clearMarkupSelection()
    }

    public func updateSelection(_ selection: PDFSelection?) {
        paneModel.updateSelection(selection)
    }

    // MARK: - Navigation

    public func goToPage(_ index: Int) {
        paneModel.goToPage(index)
    }

    public func updateCurrentPageIndex(_ index: Int) {
        paneModel.updateCurrentPageIndex(index)
    }

    public func updateViewState(
        document: PDFDocument?,
        pageIndex: Int?,
        scale: CGFloat,
        pageNavigationRevision: Int,
        zoomCommandRevision: Int
    ) {
        paneModel.updateViewState(
            document: document,
            pageIndex: pageIndex,
            scale: scale,
            pageNavigationRevision: pageNavigationRevision,
            zoomCommandRevision: zoomCommandRevision
        )
    }

    public func goToNextPage() {
        paneModel.goToNextPage()
    }

    public func goToPreviousPage() {
        paneModel.goToPreviousPage()
    }

    // MARK: - Zoom

    public func setZoomScale(_ scale: CGFloat) {
        paneModel.setZoomScale(scale)
    }

    public func zoomIn() {
        paneModel.zoomIn()
    }

    public func zoomOut() {
        paneModel.zoomOut()
    }

    public func resetZoom() {
        paneModel.resetZoom()
    }

    public func fitToWindow() {
        paneModel.fitToWindow()
    }

    public func updateEffectiveScale(_ scale: CGFloat) {
        paneModel.updateEffectiveScale(scale)
    }

    public func setAutoScaling(_ enabled: Bool) {
        paneModel.setAutoScaling(enabled)
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
