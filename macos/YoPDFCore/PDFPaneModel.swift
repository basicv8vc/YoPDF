import AppKit
import Combine
import Foundation
import PDFKit

/// Owns the independent visual, navigation, and interactive state for one PDF pane.
///
/// References a shared `PDFResourceSession` for the underlying editable document,
/// annotations, and persistence. Multiple `PDFPaneModel` instances referencing the
/// same `PDFResourceSession` navigate, zoom, select, and search independently without
/// duplicating document instances or file leases.
@MainActor
public final class PDFPaneModel: ObservableObject, Identifiable {

    public let id: PaneID
    public let resourceSession: PDFResourceSession

    // MARK: - Navigation State

    @Published public private(set) var currentPageIndex: Int = 0
    /// Monotonically incremented on explicit page navigation commands (never for scroll feedback).
    @Published public private(set) var pageNavigationRevision: Int = 0

    // MARK: - Zoom State

    /// The zoom scale the user explicitly requested. Only authoritative when `isAutoScaling` is false.
    @Published public private(set) var zoomScale: CGFloat = 1
    /// What the pane view is actually displaying. Mirrored from PDFView.
    @Published public private(set) var effectiveScale: CGFloat = 1
    @Published public private(set) var isAutoScaling: Bool = true
    /// Incremented only on explicit zoom or fit commands to distinguish from trackpad pinch.
    @Published public private(set) var zoomCommandRevision: Int = 0

    // MARK: - Local Selections

    @Published public private(set) var currentSelection: PDFSelection?
    @Published public internal(set) var selectedMarkup: MarkupSelection?

    // MARK: - Note Composer

    public let noteComposerStore: NoteComposerStore
    public var composerStore: NoteComposerStore { noteComposerStore }

    // MARK: - In-Pane Search

    public let searchSession: PDFSearchSession
    @Published public var isSearchPresented: Bool = false

    private var cancellables = Set<AnyCancellable>()

    public init(
        id: PaneID = UUID(),
        resourceSession: PDFResourceSession,
        searchDebounceNanoseconds: UInt64 = 200_000_000
    ) {
        self.id = id
        self.resourceSession = resourceSession
        self.searchSession = PDFSearchSession(
            coordinator: resourceSession.searchCoordinator,
            debounceNanoseconds: searchDebounceNanoseconds,
            paneID: id
        )
        self.noteComposerStore = NoteComposerStore()

        // Lease registration
        resourceSession.acquireLease(for: id)

        // Restore initial reading position if available
        if let url = resourceSession.fileURL,
           let pos = resourceSession.recentDocuments?.readingPosition(for: url) {
            let maxPages = max(resourceSession.pageCount, 1)
            self.currentPageIndex = min(max(pos.pageIndex, 0), maxPages - 1)
            let z = CGFloat(pos.zoomScale)
            self.zoomScale = z.isFinite ? min(max(z, PDFDocumentModel.minimumZoomScale), PDFDocumentModel.maximumZoomScale) : 1
            self.effectiveScale = self.zoomScale
            self.isAutoScaling = pos.usesAutomaticScaling
        }

        setupBindings()
    }

    deinit {
        MainActor.assumeIsolated {
            resourceSession.releaseLease(for: id)
        }
    }

    private func setupBindings() {
        searchSession.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        noteComposerStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    public var document: PDFDocument? {
        resourceSession.document
    }

    public var displayPageNumber: Int {
        resourceSession.pageCount == 0 ? 0 : currentPageIndex + 1
    }

    public func close() {
        searchSession.clear()
        noteComposerStore.discardIfClean()
        currentSelection = nil
        selectedMarkup = nil
        resourceSession.releaseLease(for: id)
    }

    // MARK: - Navigation Methods

    public func goToPage(_ index: Int) {
        let count = resourceSession.pageCount
        guard count > 0 else { return }
        let clamped = min(max(index, 0), count - 1)
        if currentPageIndex != clamped {
            currentPageIndex = clamped
        }
        pageNavigationRevision &+= 1
        persistReadingPosition()
    }

    public func goToNextPage() {
        guard currentPageIndex + 1 < resourceSession.pageCount else { return }
        goToPage(currentPageIndex + 1)
    }

    public func goToPreviousPage() {
        guard currentPageIndex > 0 else { return }
        goToPage(currentPageIndex - 1)
    }

    public func updateCurrentPageIndex(_ index: Int) {
        guard index >= 0, index < resourceSession.pageCount, index != currentPageIndex else { return }
        currentPageIndex = index
        persistReadingPosition()
    }

    public func updateViewState(
        document: PDFDocument?,
        pageIndex: Int?,
        scale: CGFloat,
        pageNavigationRevision: Int,
        zoomCommandRevision: Int
    ) {
        guard resourceSession.document === document,
              self.pageNavigationRevision == pageNavigationRevision,
              self.zoomCommandRevision == zoomCommandRevision else { return }
        if let pageIndex {
            updateCurrentPageIndex(pageIndex)
        }
        updateEffectiveScale(scale)
    }

    // MARK: - Zoom Methods

    public func setZoomScale(_ scale: CGFloat) {
        guard scale.isFinite else { return }
        zoomScale = min(max(scale, PDFDocumentModel.minimumZoomScale), PDFDocumentModel.maximumZoomScale)
        effectiveScale = zoomScale
        isAutoScaling = false
        zoomCommandRevision &+= 1
        persistReadingPosition()
    }

    private var zoomBase: CGFloat {
        isAutoScaling ? effectiveScale : zoomScale
    }

    public func zoomIn() {
        setZoomScale(zoomBase * 1.25)
    }

    public func zoomOut() {
        setZoomScale(zoomBase / 1.25)
    }

    public func resetZoom() {
        setZoomScale(1)
    }

    public func fitToWindow() {
        isAutoScaling = true
        zoomCommandRevision &+= 1
        persistReadingPosition()
    }

    public func updateEffectiveScale(_ scale: CGFloat) {
        guard scale.isFinite, scale > 0 else { return }
        if effectiveScale != scale {
            effectiveScale = scale
        }
        if !isAutoScaling {
            let manualScale = min(max(scale, PDFDocumentModel.minimumZoomScale), PDFDocumentModel.maximumZoomScale)
            if zoomScale != manualScale {
                zoomScale = manualScale
                persistReadingPosition()
            }
        }
    }

    public func setAutoScaling(_ enabled: Bool) {
        if enabled {
            fitToWindow()
        } else {
            guard isAutoScaling else { return }
            isAutoScaling = false
            zoomScale = min(max(effectiveScale, PDFDocumentModel.minimumZoomScale), PDFDocumentModel.maximumZoomScale)
            persistReadingPosition()
        }
    }

    private func persistReadingPosition() {
        guard let url = resourceSession.fileURL else { return }
        resourceSession.recentDocuments?.updateReadingPosition(
            RecentReadingPosition(
                pageIndex: currentPageIndex,
                zoomScale: Double(zoomScale),
                usesAutomaticScaling: isAutoScaling
            ),
            for: url
        )
    }

    // MARK: - Text Selection

    public func updateSelection(_ selection: PDFSelection?) {
        guard selection !== currentSelection else { return }
        currentSelection = selection
        if let selection,
           !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selectedMarkup = nil
        }
    }

    // MARK: - Markup Hit Testing & Selection

    @discardableResult
    public func selectMarkup(at point: CGPoint, on page: PDFPage) -> Bool {
        guard let document = resourceSession.document,
              page.document === document,
              let pageIndex = document.index(for: page),
              pageIndex >= 0
        else {
            selectedMarkup = nil
            return false
        }

        for annotation in page.annotations.reversed() {
            guard annotation.shouldDisplay,
                  let kind = MarkupKind(annotation: annotation),
                  MarkupGeometry.contains(annotation, point: point),
                  let selection = MarkupSelection(annotation: annotation, kind: kind, pageIndex: pageIndex)
            else { continue }
            selectedMarkup = selection
            updateSelection(nil)
            return true
        }

        selectedMarkup = nil
        return false
    }

    public func clearMarkupSelection() {
        selectedMarkup = nil
    }

    public var canModifySelectedMarkup: Bool {
        selectedMarkupContext() != nil
    }

    public var selectedMarkupIsProtected: Bool {
        selectedMarkup != nil && !canModifySelectedMarkup
    }

    private func selectedMarkupContext() -> SelectedMarkupContext? {
        guard let document = resourceSession.document,
              let selected = selectedMarkup,
              let page = document.page(at: selected.pageIndex),
              let kind = MarkupKind(annotation: selected.annotation),
              MarkupPermissions.canModify(selected.annotation, in: document, on: page),
              document.index(for: page) == selected.pageIndex
        else { return nil }
        return SelectedMarkupContext(
            annotation: selected.annotation,
            kind: kind,
            pageIndex: selected.pageIndex
        )
    }

    // MARK: - Markup Operations

    public var canAddHighlight: Bool {
        canAddMarkup(.highlight)
    }

    public func canAddMarkup(_ kind: MarkupKind) -> Bool {
        resourceSession.canAddMarkup(kind, from: currentSelection)
    }

    @discardableResult
    public func addHighlightToSelection() -> HighlightService.Summary? {
        addMarkup(.highlight)
    }

    @discardableResult
    public func addUnderlineToSelection() -> HighlightService.Summary? {
        addMarkup(.underline)
    }

    @discardableResult
    public func addMarkup(_ kind: MarkupKind) -> HighlightService.Summary? {
        guard let summary = resourceSession.addMarkup(kind, from: currentSelection) else {
            return nil
        }
        updateSelection(nil)
        return summary
    }

    @discardableResult
    public func recolorSelectedMarkup(to color: NSColor, coalescing: Bool = false) -> Bool {
        guard let context = selectedMarkupContext() else { return false }
        return resourceSession.recolorMarkup(
            context.annotation,
            on: context.pageIndex,
            to: color,
            coalescing: coalescing
        )
    }

    @discardableResult
    public func deleteSelectedMarkup() -> Bool {
        guard let context = selectedMarkupContext() else { return false }
        let success = resourceSession.deleteMarkup(context.annotation, on: context.pageIndex)
        if success {
            selectedMarkup = nil
        }
        return success
    }

    @discardableResult
    public func convertSelectedMarkup() -> Bool {
        guard let context = selectedMarkupContext(),
              let nextKind = context.kind.nextKind
        else { return false }
        let success = resourceSession.convertMarkup(context.annotation, on: context.pageIndex)
        if success {
            selectedMarkup = MarkupSelection(
                annotation: context.annotation,
                kind: nextKind,
                pageIndex: context.pageIndex
            )
        }
        return success
    }

    public func undoMarkup() -> Bool {
        resourceSession.undoMarkup()
    }

    public func redoMarkup() -> Bool {
        resourceSession.redoMarkup()
    }

    public var canUndoMarkup: Bool {
        resourceSession.canUndoMarkup
    }

    public var canRedoMarkup: Bool {
        resourceSession.canRedoMarkup
    }

    // MARK: - Note Operations

    public var canCreateNote: Bool {
        resourceSession.canCreateNote
    }

    public var canAddSelectionNote: Bool {
        guard canCreateNote, let currentSelection else { return false }
        return !(currentSelection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func selectionNoteDraft() -> NoteDraft? {
        resourceSession.selectionNoteDraft(from: currentSelection)
    }

    public func pageNoteDraft(at point: CGPoint, on page: PDFPage) -> NoteDraft? {
        resourceSession.pageNoteDraft(at: point, on: page)
    }

    public func noteSelection(at point: CGPoint, on page: PDFPage) -> NoteSelection? {
        resourceSession.noteSelection(at: point, on: page)
    }

    // MARK: - Search Delegation

    public var inputQuery: String { searchSession.inputQuery }
    public var query: String { searchSession.query }
    public var results: [PDFSelection] { searchSession.results }
    public var currentResultIndex: Int? { searchSession.currentResultIndex }
    public var isSearching: Bool { searchSession.isSearching }
    public var resultsRevision: Int { searchSession.resultsRevision }

    public func search(_ rawQuery: String) {
        searchSession.search(rawQuery, in: resourceSession.document)
    }

    public func clearSearch() {
        searchSession.clear()
    }

    public func moveSearchResult(by offset: Int) {
        searchSession.move(by: offset)
    }
}

/// Architectural container binding a visual pane ID, its pane model, and the shared resource.
@MainActor
public final class PDFPaneSession: Identifiable {
    public let id: PaneID
    public let paneModel: PDFPaneModel
    public let resourceSession: PDFResourceSession

    public init(
        paneID: PaneID = UUID(),
        paneModel: PDFPaneModel? = nil,
        resourceSession: PDFResourceSession
    ) {
        self.id = paneID
        self.resourceSession = resourceSession
        self.paneModel = paneModel ?? PDFPaneModel(id: paneID, resourceSession: resourceSession)
    }
}
