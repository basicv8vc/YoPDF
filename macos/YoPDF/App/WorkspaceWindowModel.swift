import Combine
import Foundation
import YoPDFCore

enum WorkspacePaneEntry {
    case pdf(PDFPaneSession)
    case markdown(MarkdownPaneSession)

    var kind: PaneKind {
        switch self {
        case .pdf: return .pdf
        case .markdown: return .markdown
        }
    }
}

enum PaneReplaceError: Error, Equatable, LocalizedError, Sendable {
    case targetHasUncommittedDraft
    case targetHasUnsavedDocumentChanges

    var errorDescription: String? {
        switch self {
        case .targetHasUncommittedDraft:
            return "Target pane has uncommitted note draft"
        case .targetHasUnsavedDocumentChanges:
            return "Target pane has unsaved document changes"
        }
    }
}

enum IncomingPaneResource {
    case pdf(PDFResourceSession?)
    case markdown(MarkdownResourceSession?)
}

@MainActor
final class WorkspaceTabSession: Identifiable, ObservableObject {
    let id: UUID
    @Published var layoutTree: WorkspaceLayoutTree
    @Published var activePaneID: PaneID
    private(set) var paneEntries: [PaneID: WorkspacePaneEntry]
    let navigationState: ReaderNavigationState

    private var documentModels: [PaneID: PDFDocumentModel] = [:]
    private lazy var fallbackDocumentModel = PDFDocumentModel()
    private var paneCancellables: [PaneID: [AnyCancellable]] = [:]
    private var cancellables = Set<AnyCancellable>()

    var observedPaneIDs: Set<PaneID> {
        Set(paneCancellables.keys)
    }

    /// Computed view of PDF pane sessions in this tab (single source of truth is `paneEntries`).
    var paneSessions: [PaneID: PDFPaneSession] {
        var result: [PaneID: PDFPaneSession] = [:]
        for (paneID, entry) in paneEntries {
            if case let .pdf(session) = entry {
                result[paneID] = session
            }
        }
        return result
    }

    /// Computed view of Markdown pane sessions in this tab.
    var markdownPaneSessions: [PaneID: MarkdownPaneSession] {
        var result: [PaneID: MarkdownPaneSession] = [:]
        for (paneID, entry) in paneEntries {
            if case let .markdown(session) = entry {
                result[paneID] = session
            }
        }
        return result
    }

    init(
        identity: WorkspaceTabIdentity = WorkspaceTabIdentity(),
        model: PDFDocumentModel
    ) {
        id = identity.id
        let initialPaneID = model.paneModel.id
        activePaneID = initialPaneID
        layoutTree = WorkspaceLayoutTree(leaf: initialPaneID)

        let initialSession = PDFPaneSession(
            paneID: initialPaneID,
            paneModel: model.paneModel,
            resourceSession: model.resourceSession
        )
        paneEntries = [initialPaneID: .pdf(initialSession)]
        documentModels[initialPaneID] = model
        navigationState = ReaderNavigationState()

        setupObserving(for: initialSession)
        setupNavigationObserving()
    }

    init(
        id: UUID = UUID(),
        resourceSession: PDFResourceSession,
        initialPaneID: PaneID = PaneID()
    ) {
        self.id = id
        self.activePaneID = initialPaneID
        self.layoutTree = WorkspaceLayoutTree(leaf: initialPaneID)
        let initialSession = PDFPaneSession(
            paneID: initialPaneID,
            resourceSession: resourceSession
        )
        self.paneEntries = [initialPaneID: .pdf(initialSession)]
        self.navigationState = ReaderNavigationState()

        setupObserving(for: initialSession)
        setupNavigationObserving()
    }

    init(
        id: UUID = UUID(),
        markdownResourceSession: MarkdownResourceSession,
        associatedPDFURL: URL? = nil,
        initialPaneID: PaneID = PaneID()
    ) {
        self.id = id
        self.activePaneID = initialPaneID
        self.layoutTree = WorkspaceLayoutTree(leaf: initialPaneID)
        let initialSession = MarkdownPaneSession(
            paneID: initialPaneID,
            resourceSession: markdownResourceSession,
            associatedPDFURL: associatedPDFURL
        )
        self.paneEntries = [initialPaneID: .markdown(initialSession)]
        self.navigationState = ReaderNavigationState()

        setupObserving(for: initialSession)
        setupNavigationObserving()
    }

    // MARK: - Active Pane Accessors

    func paneEntry(for paneID: PaneID) -> WorkspacePaneEntry? {
        paneEntries[paneID]
    }

    func paneKind(for paneID: PaneID) -> PaneKind? {
        paneEntries[paneID]?.kind
    }

    var activePaneKind: PaneKind {
        paneEntries[activePaneID]?.kind ?? .pdf
    }

    var activeMarkdownPaneSession: MarkdownPaneSession? {
        guard case let .markdown(session) = paneEntries[activePaneID] else { return nil }
        return session
    }

    var primaryPDFPaneSession: PDFPaneSession? {
        if case let .pdf(session) = paneEntries[activePaneID] {
            return session
        }
        for leafID in layoutTree.leafIDs {
            if case let .pdf(session) = paneEntries[leafID] {
                return session
            }
        }
        return paneSessions.values.first
    }

    var activePaneSession: PDFPaneSession? {
        primaryPDFPaneSession
    }

    var paneID: UUID {
        activePaneID.rawValue
    }

    var model: PDFDocumentModel {
        if let session = primaryPDFPaneSession {
            return model(for: session)
        }
        return fallbackDocumentModel
    }

    func model(for session: PDFPaneSession) -> PDFDocumentModel {
        if let existing = documentModels[session.id] {
            return existing
        }
        let docModel = PDFDocumentModel(
            resourceSession: session.resourceSession,
            paneModel: session.paneModel
        )
        documentModels[session.id] = docModel
        return docModel
    }

    func model(for paneID: PaneID) -> PDFDocumentModel? {
        guard case let .pdf(session) = paneEntries[paneID] else { return nil }
        return model(for: session)
    }

    var composerStore: NoteComposerStore {
        primaryPDFPaneSession?.paneModel.noteComposerStore ?? NoteComposerStore()
    }

    var searchSession: PDFSearchSession {
        primaryPDFPaneSession?.paneModel.searchSession ?? PDFSearchSession()
    }

    var hasLoadedContent: Bool {
        !markdownPaneSessions.isEmpty || uniqueResourceSessions.contains { $0.isLoaded }
    }

    var isEmptyPlaceholderTab: Bool {
        guard paneEntries.count == 1,
              let onlyEntry = paneEntries.values.first,
              case let .pdf(pdfSession) = onlyEntry
        else { return false }
        return !pdfSession.resourceSession.isLoaded
            && !pdfSession.resourceSession.hasUnsavedChanges
            && !pdfSession.paneModel.noteComposerStore.hasUncommittedChanges
    }

    /// Tab label: the primary PDF's file name, active Markdown file name, or
    /// the short placeholder for an empty workspace.
    var title: String {
        if let pdfName = primaryPDFPaneSession?.resourceSession.fileURL?.lastPathComponent {
            return pdfName
        }
        if let mdSession = activeMarkdownPaneSession ?? markdownPaneSessions.values.first {
            return mdSession.resourceSession.fileURL?.lastPathComponent ?? mdSession.resourceSession.title
        }
        return "New"
    }

    // MARK: - Resource Collections & Dirty State

    var uniqueResourceSessions: [PDFResourceSession] {
        var seen = Set<ObjectIdentifier>()
        var result: [PDFResourceSession] = []
        for session in paneSessions.values {
            let res = session.resourceSession
            let objID = ObjectIdentifier(res)
            if !seen.contains(objID) {
                seen.insert(objID)
                result.append(res)
            }
        }
        return result
    }

    var uniqueMarkdownResourceSessions: [MarkdownResourceSession] {
        var seen = Set<ObjectIdentifier>()
        var result: [MarkdownResourceSession] = []
        for session in markdownPaneSessions.values {
            let res = session.resourceSession
            let objID = ObjectIdentifier(res)
            if !seen.contains(objID) {
                seen.insert(objID)
                result.append(res)
            }
        }
        return result
    }

    var hasUncommittedChanges: Bool {
        paneSessions.values.contains { $0.paneModel.noteComposerStore.hasUncommittedChanges }
    }

    var hasUnsavedDocumentChanges: Bool {
        uniqueResourceSessions.contains { $0.hasUnsavedChanges }
            || uniqueMarkdownResourceSessions.contains { $0.hasUnsavedChanges }
    }

    /// Resolves and commits uncommitted drafts across all PDF pane sessions in this tab.
    @discardableResult
    func saveAllDrafts() -> Result<Void, NoteEditError> {
        for paneSession in paneSessions.values {
            let store = paneSession.paneModel.noteComposerStore
            guard store.hasUncommittedChanges else { continue }
            switch store.resolvePendingDraft(using: paneSession.paneModel) {
            case .success:
                continue
            case let .failure(error):
                return .failure(error)
            }
        }
        return .success(())
    }

    // MARK: - Multi-Pane Mutations

    /// Explicitly updates layout tree with observable change notification.
    func updateLayoutTree(_ newTree: WorkspaceLayoutTree) {
        layoutTree = newTree
    }

    func canSplit(
        paneID: PaneID? = nil,
        direction: LayoutInsertionDirection,
        policy: LayoutPolicy = .default,
        availableSize: CGSize? = nil
    ) -> Bool {
        let targetID = paneID ?? activePaneID
        guard paneEntries[targetID] != nil else { return false }
        return layoutTree.canInsert(
            PaneID(),
            adjacentTo: targetID,
            direction: direction,
            policy: policy,
            availableSize: availableSize
        )
    }

    @discardableResult
    func split(
        paneID: PaneID? = nil,
        direction: LayoutInsertionDirection,
        ratio: Double = 0.5,
        policy: LayoutPolicy = .default,
        availableSize: CGSize? = nil
    ) throws -> PaneID {
        let targetID = paneID ?? activePaneID
        guard let targetEntry = paneEntries[targetID] else {
            throw LayoutMutationError.targetPaneNotFound(targetID)
        }

        let newPaneID = PaneID()
        let newTree = try layoutTree.inserting(
            newPaneID,
            adjacentTo: targetID,
            direction: direction,
            ratio: ratio,
            policy: policy,
            availableSize: availableSize
        )

        switch targetEntry {
        case let .pdf(targetSession):
            let newPaneModel = PDFPaneModel(id: newPaneID, resourceSession: targetSession.resourceSession)
            newPaneModel.updateCurrentPageIndex(targetSession.paneModel.currentPageIndex)
            newPaneModel.setZoomScale(targetSession.paneModel.zoomScale)
            if targetSession.paneModel.isAutoScaling {
                newPaneModel.fitToWindow()
            }

            let newSession = PDFPaneSession(
                paneID: newPaneID,
                paneModel: newPaneModel,
                resourceSession: targetSession.resourceSession
            )

            layoutTree = newTree
            paneEntries[newPaneID] = .pdf(newSession)
            activePaneID = newPaneID
            setupObserving(for: newSession)
            objectWillChange.send()
            return newPaneID

        case let .markdown(targetSession):
            let newPaneModel = MarkdownPaneModel(
                id: newPaneID,
                resourceSession: targetSession.resourceSession,
                configuration: targetSession.paneModel.configuration,
                associatedPDFURL: targetSession.paneModel.associatedPDFURL
            )
            let newSession = MarkdownPaneSession(
                paneID: newPaneID,
                paneModel: newPaneModel,
                resourceSession: targetSession.resourceSession
            )

            layoutTree = newTree
            paneEntries[newPaneID] = .markdown(newSession)
            activePaneID = newPaneID
            setupObserving(for: newSession)
            objectWillChange.send()
            return newPaneID
        }
    }

    @discardableResult
    func splitWithMarkdown(
        resourceSession: MarkdownResourceSession,
        associatedPDFURL: URL? = nil,
        adjacentTo targetID: PaneID? = nil,
        direction: LayoutInsertionDirection = .right,
        ratio: Double = 0.5,
        policy: LayoutPolicy = .default,
        availableSize: CGSize? = nil
    ) throws -> PaneID {
        let resolvedTarget = targetID ?? activePaneID
        guard paneEntries[resolvedTarget] != nil else {
            throw LayoutMutationError.targetPaneNotFound(resolvedTarget)
        }

        let newPaneID = PaneID()
        let newTree = try layoutTree.inserting(
            newPaneID,
            adjacentTo: resolvedTarget,
            direction: direction,
            ratio: ratio,
            policy: policy,
            availableSize: availableSize
        )

        let newSession = MarkdownPaneSession(
            paneID: newPaneID,
            resourceSession: resourceSession,
            associatedPDFURL: associatedPDFURL
        )

        layoutTree = newTree
        paneEntries[newPaneID] = .markdown(newSession)
        activePaneID = newPaneID
        setupObserving(for: newSession)
        objectWillChange.send()
        return newPaneID
    }

    @discardableResult
    func replaceEmptyPlaceholderWithMarkdown(
        resourceSession: MarkdownResourceSession,
        associatedPDFURL: URL? = nil,
        paneID: PaneID = PaneID()
    ) -> PaneID? {
        guard isEmptyPlaceholderTab,
              let (oldPaneID, oldEntry) = paneEntries.first,
              case let .pdf(oldPDFSession) = oldEntry
        else { return nil }

        let newSession = MarkdownPaneSession(
            paneID: paneID,
            resourceSession: resourceSession,
            associatedPDFURL: associatedPDFURL
        )

        cancelObserving(for: oldPaneID)
        oldPDFSession.paneModel.close()
        if oldPDFSession.resourceSession.activeLeaseCount == 0 {
            oldPDFSession.resourceSession.close()
        }

        paneEntries.removeValue(forKey: oldPaneID)
        documentModels.removeValue(forKey: oldPaneID)
        paneEntries[paneID] = .markdown(newSession)
        layoutTree = WorkspaceLayoutTree(leaf: paneID)
        activePaneID = paneID
        setupObserving(for: newSession)
        objectWillChange.send()
        return paneID
    }

    @discardableResult
    func closePane(_ paneID: PaneID) throws -> Bool {
        guard paneEntries.count > 1 else {
            throw LayoutMutationError.cannotCloseOnlyPane
        }
        guard let entryToClose = paneEntries[paneID] else {
            throw LayoutMutationError.targetPaneNotFound(paneID)
        }

        switch entryToClose {
        case let .pdf(sessionToClose):
            // Direct close of a dirty pane cannot silently discard its draft
            guard !sessionToClose.paneModel.noteComposerStore.hasUncommittedChanges else {
                return false
            }
            let newTree = try layoutTree.removing(paneID)
            layoutTree = newTree
            cancelObserving(for: paneID)
            sessionToClose.paneModel.close()
            paneEntries.removeValue(forKey: paneID)
            documentModels.removeValue(forKey: paneID)

        case let .markdown(sessionToClose):
            let isFinalDirtyLease = sessionToClose.resourceSession.activeLeaseCount <= 1
                && sessionToClose.resourceSession.hasUnsavedChanges
            guard !isFinalDirtyLease else {
                return false
            }
            let newTree = try layoutTree.removing(paneID)
            layoutTree = newTree
            cancelObserving(for: paneID)
            sessionToClose.paneModel.close()
            paneEntries.removeValue(forKey: paneID)
        }

        if activePaneID == paneID {
            if let first = layoutTree.leafIDs.first {
                activePaneID = first
            }
        }
        objectWillChange.send()
        return true
    }

    @discardableResult
    func detachPaneEntry(_ paneID: PaneID) -> WorkspacePaneEntry? {
        guard let entry = paneEntries[paneID] else { return nil }
        if layoutTree.paneCount > 1 {
            if let newTree = try? layoutTree.removing(paneID) {
                layoutTree = newTree
            }
            if activePaneID == paneID {
                if let first = layoutTree.leafIDs.first {
                    activePaneID = first
                }
            }
        }
        cancelObserving(for: paneID)
        paneEntries.removeValue(forKey: paneID)
        documentModels.removeValue(forKey: paneID)
        objectWillChange.send()
        return entry
    }

    @discardableResult
    func detachPaneSession(_ paneID: PaneID) -> PDFPaneSession? {
        guard case .pdf = paneEntries[paneID] else { return nil }
        guard case let .pdf(session) = detachPaneEntry(paneID) else { return nil }
        return session
    }

    func attachTransferredPaneEntry(_ entry: WorkspacePaneEntry, newLayoutTree: WorkspaceLayoutTree) {
        let paneID: PaneID
        switch entry {
        case let .pdf(session):
            paneID = session.id
            setupObserving(for: session)
        case let .markdown(session):
            paneID = session.id
            setupObserving(for: session)
        }
        layoutTree = newLayoutTree
        paneEntries[paneID] = entry
        activePaneID = paneID
        objectWillChange.send()
    }

    func attachTransferredPaneSession(_ session: PDFPaneSession, newLayoutTree: WorkspaceLayoutTree) {
        attachTransferredPaneEntry(.pdf(session), newLayoutTree: newLayoutTree)
    }

    /// Returns an error if replacing `targetPaneID` would silently discard an uncommitted
    /// note draft or the sole surviving lease on a dirty PDF/Markdown resource.
    func replacementError(
        for targetPaneID: PaneID,
        incomingResource: IncomingPaneResource? = nil
    ) -> PaneReplaceError? {
        guard let targetEntry = paneEntries[targetPaneID] else { return nil }
        switch targetEntry {
        case let .pdf(targetSession):
            if targetSession.paneModel.noteComposerStore.hasUncommittedChanges {
                return .targetHasUncommittedDraft
            }
            let targetResource = targetSession.resourceSession
            if targetResource.hasUnsavedChanges {
                let incomingPDF: PDFResourceSession? = if case let .pdf(pdfRes) = incomingResource { pdfRes } else { nil }
                let sameResourceReused = (incomingPDF === targetResource)
                let otherLeaseExists = !targetResource.activePaneIDs.subtracting([targetPaneID]).isEmpty
                if !sameResourceReused && !otherLeaseExists {
                    return .targetHasUnsavedDocumentChanges
                }
            }
            return nil

        case let .markdown(targetSession):
            let targetResource = targetSession.resourceSession
            if targetResource.hasUnsavedChanges {
                let incomingMD: MarkdownResourceSession? = if case let .markdown(mdRes) = incomingResource { mdRes } else { nil }
                let sameResourceReused = (incomingMD === targetResource)
                let otherLeaseExists = !targetResource.activePaneIDs.subtracting([targetPaneID]).isEmpty
                if !sameResourceReused && !otherLeaseExists {
                    return .targetHasUnsavedDocumentChanges
                }
            }
            return nil
        }
    }

    func replacementError(
        for targetPaneID: PaneID,
        incomingResourceSession: PDFResourceSession?
    ) -> PaneReplaceError? {
        replacementError(for: targetPaneID, incomingResource: .pdf(incomingResourceSession))
    }

    func canReplacePane(
        _ targetPaneID: PaneID,
        incomingResource: IncomingPaneResource? = nil
    ) -> (isValid: Bool, feedback: String) {
        guard paneEntries[targetPaneID] != nil else {
            return (false, "Invalid drop target")
        }
        if let error = replacementError(for: targetPaneID, incomingResource: incomingResource) {
            return (false, error.localizedDescription)
        }
        return (true, "")
    }

    func canReplacePane(
        _ targetPaneID: PaneID,
        incomingResourceSession: PDFResourceSession?
    ) -> (isValid: Bool, feedback: String) {
        canReplacePane(targetPaneID, incomingResource: .pdf(incomingResourceSession))
    }

    private func releaseClosedPaneEntry(
        _ paneID: PaneID,
        preservingResource incomingResource: IncomingPaneResource? = nil
    ) {
        guard let oldEntry = paneEntries.removeValue(forKey: paneID) else { return }
        cancelObserving(for: paneID)
        documentModels.removeValue(forKey: paneID)
        switch oldEntry {
        case let .pdf(oldSession):
            let oldResource = oldSession.resourceSession
            let incomingPDF: PDFResourceSession? = if case let .pdf(pdfRes) = incomingResource { pdfRes } else { nil }
            oldSession.paneModel.close()
            if oldResource !== incomingPDF && oldResource.activeLeaseCount == 0 {
                oldResource.close()
            }
        case let .markdown(oldSession):
            let oldResource = oldSession.resourceSession
            let incomingMD: MarkdownResourceSession? = if case let .markdown(mdRes) = incomingResource { mdRes } else { nil }
            oldSession.paneModel.close()
            if oldResource !== incomingMD && oldResource.activeLeaseCount == 0 {
                oldResource.close()
            }
        }
    }

    func replacePaneEntry(
        _ targetPaneID: PaneID,
        with incomingEntry: WorkspacePaneEntry,
        newLayoutTree: WorkspaceLayoutTree
    ) {
        let preserving: IncomingPaneResource = switch incomingEntry {
        case let .pdf(session): .pdf(session.resourceSession)
        case let .markdown(session): .markdown(session.resourceSession)
        }
        releaseClosedPaneEntry(targetPaneID, preservingResource: preserving)
        attachTransferredPaneEntry(incomingEntry, newLayoutTree: newLayoutTree)
    }

    func replacePaneSession(
        _ targetPaneID: PaneID,
        with incomingSession: PDFPaneSession,
        newLayoutTree: WorkspaceLayoutTree
    ) {
        replacePaneEntry(targetPaneID, with: .pdf(incomingSession), newLayoutTree: newLayoutTree)
    }

    func movePaneWithinTabReplacing(
        paneID: PaneID,
        replacing targetPaneID: PaneID
    ) throws {
        guard paneID != targetPaneID else {
            throw LayoutMutationError.duplicatePaneID(paneID)
        }
        guard let sourceEntry = paneEntries[paneID] else {
            throw LayoutMutationError.targetPaneNotFound(paneID)
        }
        guard paneEntries[targetPaneID] != nil else {
            throw LayoutMutationError.targetPaneNotFound(targetPaneID)
        }
        let incomingResource: IncomingPaneResource = switch sourceEntry {
        case let .pdf(session): .pdf(session.resourceSession)
        case let .markdown(session): .markdown(session.resourceSession)
        }
        if let error = replacementError(for: targetPaneID, incomingResource: incomingResource) {
            throw error
        }

        let newTree = try layoutTree.moving(paneID, replacing: targetPaneID)
        releaseClosedPaneEntry(targetPaneID, preservingResource: incomingResource)
        layoutTree = newTree
        activePaneID = paneID
        objectWillChange.send()
    }

    func movePaneWithinTab(
        paneID: PaneID,
        adjacentTo target: PaneID,
        direction: LayoutInsertionDirection,
        ratio: Double = 0.5,
        policy: LayoutPolicy = .default,
        availableSize: CGSize? = nil
    ) throws {
        let newTree = try layoutTree.moving(
            paneID,
            adjacentTo: target,
            direction: direction,
            ratio: ratio,
            policy: policy,
            availableSize: availableSize
        )
        layoutTree = newTree
        activePaneID = paneID
        objectWillChange.send()
    }

    func setupObserving(for session: PDFPaneSession) {
        cancelObserving(for: session.id)
        let paneSubscription = session.paneModel.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        let resourceSubscription = session.resourceSession.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        paneCancellables[session.id] = [paneSubscription, resourceSubscription]
    }

    private func cancelObserving(for paneID: PaneID) {
        if let subscriptions = paneCancellables.removeValue(forKey: paneID) {
            subscriptions.forEach { $0.cancel() }
        }
    }

    func cancelAllPaneObserving() {
        for subscriptions in paneCancellables.values {
            subscriptions.forEach { $0.cancel() }
        }
        paneCancellables.removeAll()
    }

    func setupObserving(for session: MarkdownPaneSession) {
        cancelObserving(for: session.id)
        let paneSubscription = session.paneModel.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        let resourceSubscription = session.resourceSession.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        paneCancellables[session.id] = [paneSubscription, resourceSubscription]
    }

    /// The sidebar visibility and section live on `navigationState`, and the
    /// reader's conditional layout reads it. Without this forwarding the
    /// toggle only takes effect when an unrelated model change re-renders
    /// the reader, which the user sees as a delayed sidebar toggle.
    func setupNavigationObserving() {
        navigationState.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }
}

enum WorkspaceOpenResult {
    case opened(tabID: UUID)
    case activatedExisting(tabID: UUID)
    case failed(PDFDocumentModel.LoadError)
}

enum WorkspaceMarkdownOpenResult {
    case opened(tabID: UUID, paneID: PaneID)
    case activatedExisting(tabID: UUID, paneID: PaneID)
    case failed(MarkdownLoadError)
}

/// Stable owner of the PDF and Markdown runtime sessions inside one macOS window.
///
/// The value state carries tab and pane identity; this object keeps the live
/// PDFKit models, Markdown editors, note drafts, and find sessions alive across
/// SwiftUI updates.
@MainActor
final class WorkspaceWindowModel: ObservableObject {

    @Published private(set) var state: WorkspaceState
    let markdownPool: MarkdownResourcePool
    let noteAssociationStore: PaperNoteAssociationStore
    private var sessions: [UUID: WorkspaceTabSession]
    private let modelFactory: @MainActor () -> PDFDocumentModel
    private var lastDocumentRevisions: [UUID: Int] = [:]
    private var lastDraftRevisions: [UUID: Int] = [:]
    private var documentRevision = 0
    private var draftRevision = 0
    private var tabObservingCancellables: [UUID: AnyCancellable] = [:]

    init(
        markdownPool: MarkdownResourcePool? = nil,
        noteAssociationStore: PaperNoteAssociationStore? = nil,
        modelFactory: @escaping @MainActor () -> PDFDocumentModel
    ) {
        self.markdownPool = markdownPool ?? MarkdownResourcePool()
        self.noteAssociationStore = noteAssociationStore ?? PaperNoteAssociationStore()
        let firstModel = modelFactory()
        let firstIdentity = WorkspaceTabIdentity(paneID: firstModel.paneModel.id.rawValue)
        self.modelFactory = modelFactory
        state = WorkspaceState(initialTab: firstIdentity)
        let initialSession = WorkspaceTabSession(
            identity: firstIdentity,
            model: firstModel
        )
        sessions = [firstIdentity.id: initialSession]
        observeTabSession(initialSession)
    }

    var tabs: [WorkspaceTabSession] {
        state.tabs.compactMap { sessions[$0.id] }
    }

    var activeTab: WorkspaceTabSession {
        guard let activeTabID = state.activeTabID,
              let session = sessions[activeTabID]
        else {
            preconditionFailure("A workspace window must always have an active tab.")
        }
        return session
    }

    var activeTabID: UUID { activeTab.id }
    var activePaneID: UUID { activeTab.paneID }
    var activeLayoutPaneID: PaneID { activeTab.activePaneID }

    func session(tabID: UUID) -> WorkspaceTabSession? {
        sessions[tabID]
    }

    /// Resource sessions whose pane leases all live inside `tabID`.
    ///
    /// Closing the tab releases those leases, so these are the only resources
    /// whose document state the close may prompt for, discard, or destroy.
    /// A resource that is still leased by a pane in another tab survives the
    /// close: its dirty state, pending autosave, and markup undo history must
    /// stay untouched for the remaining panes.
    private func resourceSessionsLosingFinalPane(in tabID: UUID) -> [PDFResourceSession] {
        guard let session = sessions[tabID] else { return [] }
        let tabPaneIDs = Set(session.paneEntries.keys)
        return session.uniqueResourceSessions.filter { $0.activePaneIDs.isSubset(of: tabPaneIDs) }
    }

    private func markdownResourceSessionsLosingFinalPane(in tabID: UUID) -> [MarkdownResourceSession] {
        guard let session = sessions[tabID] else { return [] }
        let tabPaneIDs = Set(session.paneEntries.keys)
        return session.uniqueMarkdownResourceSessions.filter { $0.activePaneIDs.isSubset(of: tabPaneIDs) }
    }

    func closeTabPrompt(tabID: UUID) -> ReaderPrompt? {
        guard let session = sessions[tabID] else { return nil }
        let hasDirtyPDF = resourceSessionsLosingFinalPane(in: tabID).contains { $0.hasUnsavedChanges }
        let hasDirtyMarkdown = markdownResourceSessionsLosingFinalPane(in: tabID).contains { $0.hasUnsavedChanges }
        return ReaderPromptPolicy.prompt(
            for: .closeTab,
            draftHasChanges: session.hasUncommittedChanges,
            documentHasChanges: hasDirtyPDF || hasDirtyMarkdown
        )
    }

    func closePanePrompt(tabID: UUID? = nil, paneID: PaneID? = nil) -> ReaderPrompt? {
        let targetTabID = tabID ?? activeTabID
        guard let session = sessions[targetTabID] else { return nil }
        let targetPaneID = paneID ?? session.activePaneID
        guard let entry = session.paneEntry(for: targetPaneID) else { return nil }
        switch entry {
        case let .pdf(paneSession):
            return ReaderPromptPolicy.prompt(
                for: .closeTab,
                draftHasChanges: paneSession.paneModel.noteComposerStore.hasUncommittedChanges,
                documentHasChanges: false
            )
        case let .markdown(mdSession):
            let isFinalLease = mdSession.resourceSession.activeLeaseCount <= 1
            return ReaderPromptPolicy.prompt(
                for: .closeTab,
                draftHasChanges: false,
                documentHasChanges: isFinalLease && mdSession.resourceSession.hasUnsavedChanges
            )
        }
    }

    func activate(tabID: UUID) {
        guard state.activate(tabID: tabID) else { return }
    }

    func activate(paneID: PaneID, in tabID: UUID? = nil) {
        let targetTabID = tabID ?? activeTabID
        guard let session = sessions[targetTabID],
              session.paneEntries[paneID] != nil else { return }
        session.activePaneID = paneID
        objectWillChange.send()
    }

    @discardableResult
    func canSplit(
        in tabID: UUID? = nil,
        paneID: PaneID? = nil,
        direction: LayoutInsertionDirection,
        policy: LayoutPolicy = .default,
        availableSize: CGSize? = nil
    ) -> Bool {
        let targetTabID = tabID ?? activeTabID
        guard let session = sessions[targetTabID] else { return false }
        return session.canSplit(
            paneID: paneID,
            direction: direction,
            policy: policy,
            availableSize: availableSize
        )
    }

    @discardableResult
    func splitActivePane(
        direction: LayoutInsertionDirection,
        ratio: Double = 0.5,
        policy: LayoutPolicy = .default,
        availableSize: CGSize? = nil
    ) throws -> PaneID {
        let newPaneID = try activeTab.split(
            direction: direction,
            ratio: ratio,
            policy: policy,
            availableSize: availableSize
        )
        objectWillChange.send()
        return newPaneID
    }

    @discardableResult
    func splitPane(
        paneID: PaneID,
        in tabID: UUID? = nil,
        direction: LayoutInsertionDirection,
        ratio: Double = 0.5,
        policy: LayoutPolicy = .default,
        availableSize: CGSize? = nil
    ) throws -> PaneID {
        let targetTabID = tabID ?? activeTabID
        guard let session = sessions[targetTabID] else {
            throw LayoutMutationError.targetPaneNotFound(paneID)
        }
        let newPaneID = try session.split(
            paneID: paneID,
            direction: direction,
            ratio: ratio,
            policy: policy,
            availableSize: availableSize
        )
        objectWillChange.send()
        return newPaneID
    }

    /// Finds any live PDFResourceSession in the workspace that references the specified file URL.
    func findResourceSession(for url: URL) -> PDFResourceSession? {
        for tab in tabs {
            for session in tab.uniqueResourceSessions {
                if let fileURL = session.fileURL,
                   fileURL.standardizedFileURL == url.standardizedFileURL {
                    return session
                }
            }
        }
        return nil
    }

    /// Finds any live MarkdownResourceSession in the workspace that references `url`.
    func findMarkdownResourceSession(for url: URL) -> MarkdownResourceSession? {
        markdownPool.session(for: url)
    }

    /// Safely closes a tab that has had all its pane sessions transferred out.
    /// Does NOT close any resource sessions or pane models since they were transferred.
    func closeEmptyTabAfterTransfer(_ tabID: UUID) {
        guard let session = sessions[tabID], session.paneEntries.isEmpty else { return }
        sessions.removeValue(forKey: tabID)
        tabObservingCancellables.removeValue(forKey: tabID)
        _ = state.close(tabID: tabID)
        if state.activeTabID == tabID {
            if let nextTab = state.tabs.first {
                state.activate(tabID: nextTab.id)
            }
        }
        objectWillChange.send()
    }

    /// Moves a pane from a source tab to adjacent to a target pane in a destination tab.
    /// Supports both intra-tab moves and inter-tab transfers while preserving all sessions and drafts.
    @discardableResult
    func movePane(
        sourceTabID: UUID,
        paneID: PaneID,
        toDestinationTabID destinationTabID: UUID,
        adjacentTo targetPaneID: PaneID,
        direction: LayoutInsertionDirection,
        ratio: Double = 0.5,
        policy: LayoutPolicy = .default,
        availableSize: CGSize? = nil
    ) throws -> PaneID {
        if sourceTabID == destinationTabID {
            guard let tab = sessions[sourceTabID] else {
                throw LayoutMutationError.targetPaneNotFound(targetPaneID)
            }
            try tab.movePaneWithinTab(
                paneID: paneID,
                adjacentTo: targetPaneID,
                direction: direction,
                ratio: ratio,
                policy: policy,
                availableSize: availableSize
            )
            objectWillChange.send()
            return paneID
        }

        // Cross-tab transfer
        guard let sourceTab = sessions[sourceTabID] else {
            throw LayoutMutationError.targetPaneNotFound(paneID)
        }
        guard let destinationTab = sessions[destinationTabID] else {
            throw LayoutMutationError.targetPaneNotFound(targetPaneID)
        }
        guard sourceTab.paneEntries[paneID] != nil else {
            throw LayoutMutationError.targetPaneNotFound(paneID)
        }
        guard destinationTab.paneEntries[targetPaneID] != nil else {
            throw LayoutMutationError.targetPaneNotFound(targetPaneID)
        }
        guard destinationTab.layoutTree.paneCount < policy.maxPanes else {
            throw LayoutMutationError.maximumPaneLimitReached(limit: policy.maxPanes)
        }

        // Validate destination insertion before mutating anything
        let newTree = try destinationTab.layoutTree.inserting(
            paneID,
            adjacentTo: targetPaneID,
            direction: direction,
            ratio: ratio,
            policy: policy,
            availableSize: availableSize
        )

        let isSourceTabEmptying = (sourceTab.layoutTree.paneCount <= 1)

        // Detach from source without destroying session
        guard let transferredEntry = sourceTab.detachPaneEntry(paneID) else {
            throw LayoutMutationError.targetPaneNotFound(paneID)
        }

        if isSourceTabEmptying {
            closeEmptyTabAfterTransfer(sourceTabID)
        }

        // Attach to destination
        destinationTab.attachTransferredPaneEntry(transferredEntry, newLayoutTree: newTree)
        state.activate(tabID: destinationTab.id)
        destinationTab.activePaneID = paneID
        objectWillChange.send()
        return paneID
    }

    /// Moves an existing pane to occupy/replace `targetPaneID` across or within tabs,
    /// closing the replaced pane if it has no unsaved work while keeping the moved
    /// pane's state and resource session intact.
    @discardableResult
    func movePaneReplacing(
        sourceTabID: UUID,
        paneID: PaneID,
        toDestinationTabID destinationTabID: UUID,
        replacing targetPaneID: PaneID
    ) throws -> PaneID {
        if sourceTabID == destinationTabID {
            guard let tab = sessions[sourceTabID] else {
                throw LayoutMutationError.targetPaneNotFound(targetPaneID)
            }
            try tab.movePaneWithinTabReplacing(paneID: paneID, replacing: targetPaneID)
            objectWillChange.send()
            return paneID
        }

        guard let sourceTab = sessions[sourceTabID],
              let sourceEntry = sourceTab.paneEntry(for: paneID) else {
            throw LayoutMutationError.targetPaneNotFound(paneID)
        }
        guard let destinationTab = sessions[destinationTabID],
              destinationTab.paneEntry(for: targetPaneID) != nil else {
            throw LayoutMutationError.targetPaneNotFound(targetPaneID)
        }

        let incomingResource: IncomingPaneResource = switch sourceEntry {
        case let .pdf(session): .pdf(session.resourceSession)
        case let .markdown(session): .markdown(session.resourceSession)
        }
        if let error = destinationTab.replacementError(
            for: targetPaneID,
            incomingResource: incomingResource
        ) {
            throw error
        }

        let newTree = try destinationTab.layoutTree.replacing(targetPaneID, with: paneID)
        let isSourceTabEmptying = (sourceTab.layoutTree.paneCount <= 1)

        guard let transferredEntry = sourceTab.detachPaneEntry(paneID) else {
            throw LayoutMutationError.targetPaneNotFound(paneID)
        }

        if isSourceTabEmptying {
            closeEmptyTabAfterTransfer(sourceTabID)
        }

        destinationTab.replacePaneEntry(targetPaneID, with: transferredEntry, newLayoutTree: newTree)
        state.activate(tabID: destinationTab.id)
        destinationTab.activePaneID = paneID
        objectWillChange.send()
        return paneID
    }

    private func resolveResourceSession(
        for url: URL,
        existingResource: PDFResourceSession?
    ) -> Result<PDFResourceSession, Error> {
        if let existingResource {
            return .success(existingResource)
        }
        let newResource = PDFResourceSession()
        guard newResource.open(url: url) else {
            let error = newResource.lastError ?? .unreadable
            newResource.close()
            return .failure(error)
        }
        return .success(newResource)
    }

    /// Opens a local PDF file from Finder into a split adjacent to a target pane.
    /// Validates destination layout and file before committing layout mutations.
    @discardableResult
    func openPDFInSplit(
        url: URL,
        in tabID: UUID? = nil,
        adjacentTo targetPaneID: PaneID,
        direction: LayoutInsertionDirection,
        ratio: Double = 0.5,
        policy: LayoutPolicy = .default,
        availableSize: CGSize? = nil
    ) -> Result<PaneID, Error> {
        guard url.isFileURL else {
            return .failure(PDFDocumentModel.LoadError.notAFileURL)
        }
        let targetTabID = tabID ?? activeTabID
        guard let destinationTab = sessions[targetTabID] else {
            return .failure(LayoutMutationError.targetPaneNotFound(targetPaneID))
        }

        // 1. Validate destination layout first, before opening any file or creating a resource
        let candidatePaneID = PaneID()
        let candidateTree: WorkspaceLayoutTree
        do {
            candidateTree = try destinationTab.layoutTree.inserting(
                candidatePaneID,
                adjacentTo: targetPaneID,
                direction: direction,
                ratio: ratio,
                policy: policy,
                availableSize: availableSize
            )
        } catch {
            return .failure(error)
        }

        // 2. Reuse existing resourceSession if file is already open, or open a fresh resourceSession
        let existing = findResourceSession(for: url)
        let resourceSessionToUse: PDFResourceSession
        switch resolveResourceSession(for: url, existingResource: existing) {
        case let .success(session):
            resourceSessionToUse = session
        case let .failure(error):
            return .failure(error)
        }

        // 3. Commit layout mutation using the pre-validated tree
        let newPaneModel = PDFPaneModel(id: candidatePaneID, resourceSession: resourceSessionToUse)
        let newSession = PDFPaneSession(
            paneID: candidatePaneID,
            paneModel: newPaneModel,
            resourceSession: resourceSessionToUse
        )

        destinationTab.attachTransferredPaneEntry(.pdf(newSession), newLayoutTree: candidateTree)
        objectWillChange.send()
        return .success(candidatePaneID)
    }

    /// Opens a local Markdown file into a split adjacent to a target pane.
    @discardableResult
    func openMarkdownInSplit(
        url: URL,
        associatedPDFURL: URL? = nil,
        in tabID: UUID? = nil,
        adjacentTo targetPaneID: PaneID,
        direction: LayoutInsertionDirection = .right,
        ratio: Double = 0.5,
        policy: LayoutPolicy = .default,
        availableSize: CGSize? = nil
    ) -> Result<PaneID, Error> {
        guard url.isFileURL else {
            return .failure(MarkdownLoadError.notAFileURL)
        }
        let targetTabID = tabID ?? activeTabID
        guard let destinationTab = sessions[targetTabID] else {
            return .failure(LayoutMutationError.targetPaneNotFound(targetPaneID))
        }

        // 1. Validate destination layout before touching disk.
        let candidatePaneID = PaneID()
        let candidateTree: WorkspaceLayoutTree
        do {
            candidateTree = try destinationTab.layoutTree.inserting(
                candidatePaneID,
                adjacentTo: targetPaneID,
                direction: direction,
                ratio: ratio,
                policy: policy,
                availableSize: availableSize
            )
        } catch {
            return .failure(error)
        }

        // 2. Open or share session via MarkdownResourcePool.
        let markdownSession: MarkdownResourceSession
        switch markdownPool.open(url: url, for: candidatePaneID) {
        case let .success(opened):
            markdownSession = opened
        case let .failure(error):
            return .failure(error)
        }

        // 3. Commit pane entry.
        let paneSession = MarkdownPaneSession(
            paneID: candidatePaneID,
            resourceSession: markdownSession,
            associatedPDFURL: associatedPDFURL
        )
        destinationTab.attachTransferredPaneEntry(.markdown(paneSession), newLayoutTree: candidateTree)
        objectWillChange.send()
        return .success(candidatePaneID)
    }

    /// Opens a local PDF file from Finder by occupying/replacing `targetPaneID`.
    /// Validates target pane safety, layout, and file openability before mutating state.
    @discardableResult
    func openPDFReplacingPane(
        url: URL,
        in tabID: UUID? = nil,
        replacing targetPaneID: PaneID
    ) -> Result<PaneID, Error> {
        guard url.isFileURL else {
            return .failure(PDFDocumentModel.LoadError.notAFileURL)
        }
        let targetTabID = tabID ?? activeTabID
        guard let destinationTab = sessions[targetTabID],
              destinationTab.paneEntry(for: targetPaneID) != nil else {
            return .failure(LayoutMutationError.targetPaneNotFound(targetPaneID))
        }

        // 1. Check unsaved drafts or orphaned dirty document edits before opening anything
        let existing = findResourceSession(for: url)
        if let error = destinationTab.replacementError(for: targetPaneID, incomingResource: .pdf(existing)) {
            return .failure(error)
        }

        let candidatePaneID = PaneID()
        let candidateTree: WorkspaceLayoutTree
        do {
            candidateTree = try destinationTab.layoutTree.replacing(targetPaneID, with: candidatePaneID)
        } catch {
            return .failure(error)
        }

        // 2. Acquire/validate incoming document before mutating the target pane
        let resourceSessionToUse: PDFResourceSession
        switch resolveResourceSession(for: url, existingResource: existing) {
        case let .success(session):
            resourceSessionToUse = session
        case let .failure(error):
            return .failure(error)
        }

        // 3. Swap target pane cleanly after acquisition succeeds
        let newPaneModel = PDFPaneModel(id: candidatePaneID, resourceSession: resourceSessionToUse)
        let newSession = PDFPaneSession(
            paneID: candidatePaneID,
            paneModel: newPaneModel,
            resourceSession: resourceSessionToUse
        )

        destinationTab.replacePaneEntry(targetPaneID, with: .pdf(newSession), newLayoutTree: candidateTree)
        objectWillChange.send()
        return .success(candidatePaneID)
    }

    /// Opens a local Markdown file by occupying/replacing `targetPaneID`.
    @discardableResult
    func openMarkdownReplacingPane(
        url: URL,
        associatedPDFURL: URL? = nil,
        in tabID: UUID? = nil,
        replacing targetPaneID: PaneID
    ) -> Result<PaneID, Error> {
        guard url.isFileURL else {
            return .failure(MarkdownLoadError.notAFileURL)
        }
        let targetTabID = tabID ?? activeTabID
        guard let destinationTab = sessions[targetTabID],
              destinationTab.paneEntry(for: targetPaneID) != nil else {
            return .failure(LayoutMutationError.targetPaneNotFound(targetPaneID))
        }

        let existing = findMarkdownResourceSession(for: url)
        if let error = destinationTab.replacementError(for: targetPaneID, incomingResource: .markdown(existing)) {
            return .failure(error)
        }

        let candidatePaneID = PaneID()
        let candidateTree: WorkspaceLayoutTree
        do {
            candidateTree = try destinationTab.layoutTree.replacing(targetPaneID, with: candidatePaneID)
        } catch {
            return .failure(error)
        }

        let markdownSession: MarkdownResourceSession
        switch markdownPool.open(url: url, for: candidatePaneID) {
        case let .success(opened):
            markdownSession = opened
        case let .failure(error):
            return .failure(error)
        }

        let paneSession = MarkdownPaneSession(
            paneID: candidatePaneID,
            resourceSession: markdownSession,
            associatedPDFURL: associatedPDFURL
        )
        destinationTab.replacePaneEntry(targetPaneID, with: .markdown(paneSession), newLayoutTree: candidateTree)
        objectWillChange.send()
        return .success(candidatePaneID)
    }

    /// Inserts an already-opened `MarkdownResourceSession` (such as a freshly
    /// created paper note) into a split adjacent to `targetPaneID`.
    @discardableResult
    func openMarkdownSessionInSplit(
        session markdownSession: MarkdownResourceSession,
        associatedPDFURL: URL? = nil,
        in tabID: UUID? = nil,
        adjacentTo targetPaneID: PaneID,
        direction: LayoutInsertionDirection = .right,
        ratio: Double = 0.5,
        policy: LayoutPolicy = .default,
        availableSize: CGSize? = nil
    ) -> Result<PaneID, Error> {
        let targetTabID = tabID ?? activeTabID
        guard let destinationTab = sessions[targetTabID] else {
            return .failure(LayoutMutationError.targetPaneNotFound(targetPaneID))
        }

        let candidatePaneID = PaneID()
        let candidateTree: WorkspaceLayoutTree
        do {
            candidateTree = try destinationTab.layoutTree.inserting(
                candidatePaneID,
                adjacentTo: targetPaneID,
                direction: direction,
                ratio: ratio,
                policy: policy,
                availableSize: availableSize
            )
        } catch {
            return .failure(error)
        }

        markdownPool.register(markdownSession, for: candidatePaneID)
        let paneSession = MarkdownPaneSession(
            paneID: candidatePaneID,
            resourceSession: markdownSession,
            associatedPDFURL: associatedPDFURL
        )
        destinationTab.attachTransferredPaneEntry(.markdown(paneSession), newLayoutTree: candidateTree)
        objectWillChange.send()
        return .success(candidatePaneID)
    }

    /// Activates an existing Markdown pane in the target tab for `url` (or `session`)
    /// if already open, or inserts a split pane adjacent to `sourcePaneID`.
    @discardableResult
    func openOrActivateMarkdown(
        url: URL,
        associatedPDFURL: URL? = nil,
        in tabID: UUID? = nil,
        preferredSplitFrom sourcePaneID: PaneID,
        direction: LayoutInsertionDirection = .right,
        availableSize: CGSize? = nil
    ) -> Result<PaneID, Error> {
        let targetTabID = tabID ?? activeTabID
        guard let destinationTab = sessions[targetTabID] else {
            return .failure(LayoutMutationError.targetPaneNotFound(sourcePaneID))
        }

        let canonicalTarget = url.resolvingSymlinksInPath().standardizedFileURL
        if let existingPane = destinationTab.markdownPaneSessions.values.first(where: { mdSession in
            mdSession.resourceSession.fileURL?.resolvingSymlinksInPath().standardizedFileURL == canonicalTarget
        }) {
            destinationTab.activePaneID = existingPane.id
            objectWillChange.send()
            return .success(existingPane.id)
        }

        return openMarkdownInSplit(
            url: url,
            associatedPDFURL: associatedPDFURL,
            in: targetTabID,
            adjacentTo: sourcePaneID,
            direction: direction,
            policy: .default,
            availableSize: availableSize
        )
    }

    /// Opens an already-created `MarkdownResourceSession` in an existing pane if present
    /// in the active tab, or splits adjacent to `sourcePaneID`.
    @discardableResult
    func openOrActivateMarkdownSession(
        _ markdownSession: MarkdownResourceSession,
        associatedPDFURL: URL? = nil,
        in tabID: UUID? = nil,
        preferredSplitFrom sourcePaneID: PaneID,
        direction: LayoutInsertionDirection = .right,
        availableSize: CGSize? = nil
    ) -> Result<PaneID, Error> {
        let targetTabID = tabID ?? activeTabID
        guard let destinationTab = sessions[targetTabID] else {
            return .failure(LayoutMutationError.targetPaneNotFound(sourcePaneID))
        }

        if let existingPane = destinationTab.markdownPaneSessions.values.first(where: {
            $0.resourceSession === markdownSession
        }) {
            destinationTab.activePaneID = existingPane.id
            objectWillChange.send()
            return .success(existingPane.id)
        }

        return openMarkdownSessionInSplit(
            session: markdownSession,
            associatedPDFURL: associatedPDFURL,
            in: targetTabID,
            adjacentTo: sourcePaneID,
            direction: direction,
            policy: .default,
            availableSize: availableSize
        )
    }

    /// Validates whether dropping `payload` onto `targetPaneID` at `zone` in `tabID` can commit,
    /// matching the commit-time safety and rebalanced layout checks.
    func validateDrop(
        on targetPaneID: PaneID,
        in tabID: UUID,
        payload: DropPayload?,
        zone: PaneDropZone,
        availableSize: CGSize?
    ) -> (isValid: Bool, feedback: String) {
        guard let tab = sessions[tabID],
              tab.paneEntry(for: targetPaneID) != nil else {
            return (false, "Invalid drop target")
        }

        let dragPayload: PaneDragPayload?
        let fileURL: URL?
        switch payload {
        case let .pane(panePayload):
            dragPayload = panePayload
            fileURL = nil
        case let .fileURL(url):
            dragPayload = nil
            fileURL = url
        case nil:
            dragPayload = nil
            fileURL = nil
        }

        let resolvedSourcePaneID: PaneID? = dragPayload.flatMap { payload in
            payload.sourcePaneID ?? sessions[payload.sourceTabID]?.layoutTree.leafIDs.first
        }

        if let dragPayload,
           dragPayload.sourceTabID == tabID,
           resolvedSourcePaneID == targetPaneID {
            return (false, "Cannot drop a pane onto itself")
        }

        if let fileURL, !fileURL.isFileURL {
            return (false, "Invalid drop target")
        }

        guard let direction = zone.insertionDirection else {
            let incomingResource: IncomingPaneResource?
            if let fileURL {
                if MarkdownResourceSession.isSupportedMarkdownFile(fileURL) {
                    incomingResource = .markdown(findMarkdownResourceSession(for: fileURL))
                } else {
                    incomingResource = .pdf(findResourceSession(for: fileURL))
                }
            } else if let dragPayload, let sourceID = resolvedSourcePaneID {
                switch sessions[dragPayload.sourceTabID]?.paneEntry(for: sourceID) {
                case let .pdf(session):
                    incomingResource = .pdf(session.resourceSession)
                case let .markdown(session):
                    incomingResource = .markdown(session.resourceSession)
                case .none:
                    incomingResource = nil
                }
            } else {
                incomingResource = nil
            }
            return tab.canReplacePane(targetPaneID, incomingResource: incomingResource)
        }

        guard let rootSize = availableSize else {
            return (false, "Workspace layout is not ready")
        }

        let isIntraTabMove = (dragPayload?.sourceTabID == tabID && resolvedSourcePaneID != nil)
        if isIntraTabMove {
            guard let sourceID = resolvedSourcePaneID else {
                return (false, "Invalid drag source")
            }
            guard tab.layoutTree.canMove(
                sourceID,
                adjacentTo: targetPaneID,
                direction: direction,
                policy: .default,
                availableSize: rootSize
            ) else {
                return (false, "Pane is too small to split \(direction.rawValue)")
            }
            return (true, "")
        }

        do {
            _ = try tab.layoutTree.inserting(
                PaneID(),
                adjacentTo: targetPaneID,
                direction: direction,
                policy: .default,
                availableSize: rootSize
            )
            return (true, "")
        } catch let error as LayoutMutationError {
            switch error {
            case .maximumPaneLimitReached(let limit):
                return (false, "Maximum \(limit) panes limit reached")
            case .targetPaneNotFound, .duplicatePaneID, .cannotCloseOnlyPane:
                return (false, "Invalid drop target")
            case .insufficientSpace:
                if let unconstrainedTree = try? tab.layoutTree.inserting(
                    PaneID(),
                    adjacentTo: targetPaneID,
                    direction: direction,
                    policy: .default,
                    availableSize: nil
                ) {
                    let required = unconstrainedTree.minimumRequiredSize(policy: .default)
                    if required.width > rootSize.width {
                        return (false, "Width too narrow to split")
                    }
                    if required.height > rootSize.height {
                        return (false, "Height too short to split")
                    }
                }
                return (false, direction.axis == .horizontal ? "Width too narrow to split" : "Height too short to split")
            }
        } catch {
            return (false, "Invalid drop target")
        }
    }

    /// Updates layout tree for the tab with observable publication.
    func updateLayoutTree(_ newTree: WorkspaceLayoutTree, in tabID: UUID? = nil) {
        let targetTabID = tabID ?? activeTabID
        guard let session = sessions[targetTabID] else { return }
        session.updateLayoutTree(newTree)
        objectWillChange.send()
    }

    /// Resolves and commits drafts across all panes in all tabs.
    @discardableResult
    func saveAllWorkspaceDrafts() -> Result<Void, NoteEditError> {
        for tab in tabs where tab.hasUncommittedChanges {
            let result = tab.saveAllDrafts()
            if case .failure = result {
                return result
            }
        }
        return .success(())
    }

    @discardableResult
    func closePane(
        tabID: UUID? = nil,
        paneID: PaneID? = nil
    ) throws -> Bool {
        let targetTabID = tabID ?? activeTabID
        guard let session = sessions[targetTabID] else { return false }
        let targetPaneID = paneID ?? session.activePaneID
        guard let entry = session.paneEntry(for: targetPaneID) else { return false }
        switch entry {
        case let .pdf(paneSession):
            guard !paneSession.paneModel.noteComposerStore.hasUncommittedChanges else {
                return false
            }
        case let .markdown(mdSession):
            if mdSession.resourceSession.activeLeaseCount <= 1
                && mdSession.resourceSession.hasUnsavedChanges {
                return false
            }
        }
        let closed = try session.closePane(targetPaneID)
        if closed {
            objectWillChange.send()
        }
        return closed
    }

    /// Commits a tab strip drag. The ordering rule lives in `WorkspaceState`;
    /// this republishes the result so the tab strip and the reader's active
    /// model stay in sync without touching any PDF session.
    @discardableResult
    func moveTab(tabID: UUID, toInsertionIndex insertionIndex: Int) -> Bool {
        state.move(tabID: tabID, toInsertionIndex: insertionIndex)
    }

    /// Keyboard / context-menu counterpart of a drag: slides one tab by a
    /// single slot. The ordering rule stays in `WorkspaceState`, and no PDF
    /// session is touched.
    @discardableResult
    func moveTab(tabID: UUID, direction: WorkspaceTabDirection) -> Bool {
        state.move(tabID: tabID, direction: direction)
    }

    /// Menu-bar commands move the selected tab of the focused window.
    @discardableResult
    func moveActiveTab(direction: WorkspaceTabDirection) -> Bool {
        state.moveActiveTab(direction: direction)
    }

    /// Terminal-style cyclic tab selection. The wrapping rule lives in
    /// `WorkspaceState`; this only forwards to the window's published state so
    /// the tab strip and the reader's focused model update together.
    func activateAdjacentTab(direction: WorkspaceTabDirection) {
        _ = state.activateAdjacentTab(direction: direction)
    }

    @discardableResult
    func createTab() -> UUID {
        let session = makeSession()
        _ = state.insert(WorkspaceTabIdentity(id: session.id, paneID: session.paneID))
        sessions[session.id] = session
        observeTabSession(session)
        return session.id
    }

    /// Opens a PDF in the active empty tab, or adds a new tab after a successful
    /// open. An unreadable candidate never replaces an already open document.
    @discardableResult
    func open(
        _ url: URL,
        relinking recentDocument: RecentDocument? = nil
    ) -> WorkspaceOpenResult {
        guard url.isFileURL else { return .failed(.notAFileURL) }

        if let existing = tabs.first(where: {
            $0.uniqueResourceSessions.contains(where: {
                $0.fileURL?.standardizedFileURL == url.standardizedFileURL
            })
        }) {
            activate(tabID: existing.id)
            if let matchingPane = existing.paneSessions.values.first(where: {
                $0.resourceSession.fileURL?.standardizedFileURL == url.standardizedFileURL
            }) {
                existing.activePaneID = matchingPane.id
                objectWillChange.send()
            }
            return .activatedExisting(tabID: existing.id)
        }

        let current = activeTab
        if current.isEmptyPlaceholderTab {
            let opened = current.model.open(url: url, relinking: recentDocument)
            if opened { return .opened(tabID: current.id) }
            return .failed(current.model.lastError ?? .unreadable)
        }

        let candidate = makeSession()
        guard candidate.model.open(url: url, relinking: recentDocument) else {
            let error = candidate.model.lastError ?? .unreadable
            for paneSession in candidate.paneSessions.values {
                paneSession.paneModel.close()
            }
            for resourceSession in candidate.uniqueResourceSessions {
                resourceSession.close()
            }
            return .failed(error)
        }

        _ = state.insert(WorkspaceTabIdentity(id: candidate.id, paneID: candidate.paneID))
        sessions[candidate.id] = candidate
        observeTabSession(candidate)
        return .opened(tabID: candidate.id)
    }

    /// Opens a Markdown file in the active empty tab or in a new tab (or activates
    /// an existing tab/pane already showing that file).
    @discardableResult
    func openMarkdown(
        _ url: URL,
        associatedPDFURL: URL? = nil
    ) -> WorkspaceMarkdownOpenResult {
        guard url.isFileURL else { return .failed(.notAFileURL) }
        guard MarkdownResourceSession.isSupportedMarkdownFile(url) else {
            return .failed(.unsupportedType(url.pathExtension))
        }

        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        if let existingTab = tabs.first(where: { tab in
            tab.markdownPaneSessions.values.contains(where: {
                $0.resourceSession.fileURL?.resolvingSymlinksInPath().standardizedFileURL == canonical
            })
        }), let existingPane = existingTab.markdownPaneSessions.values.first(where: {
            $0.resourceSession.fileURL?.resolvingSymlinksInPath().standardizedFileURL == canonical
        }) {
            activate(tabID: existingTab.id)
            existingTab.activePaneID = existingPane.id
            objectWillChange.send()
            return .activatedExisting(tabID: existingTab.id, paneID: existingPane.id)
        }

        let candidatePaneID = PaneID()
        let mdSession: MarkdownResourceSession
        switch markdownPool.open(url: url, for: candidatePaneID) {
        case let .success(opened):
            mdSession = opened
        case let .failure(error):
            return .failed(error)
        }

        let current = activeTab
        if current.isEmptyPlaceholderTab,
           let replacedPaneID = replaceEmptyPlaceholderWithMarkdown(
               in: current.id,
               session: mdSession,
               associatedPDFURL: associatedPDFURL
           ) {
            // Transfer lease from temporary candidatePaneID to the real paneID.
            mdSession.releaseLease(for: candidatePaneID)
            return .opened(tabID: current.id, paneID: replacedPaneID)
        }

        let newTab = WorkspaceTabSession(
            markdownResourceSession: mdSession,
            associatedPDFURL: associatedPDFURL,
            initialPaneID: candidatePaneID
        )
        _ = state.insert(WorkspaceTabIdentity(id: newTab.id, paneID: candidatePaneID.rawValue))
        sessions[newTab.id] = newTab
        observeTabSession(newTab)
        objectWillChange.send()
        return .opened(tabID: newTab.id, paneID: candidatePaneID)
    }

    /// Replaces an empty placeholder tab with `markdownSession` while ensuring
    /// the session is registered and leased in `markdownPool`.
    @discardableResult
    func replaceEmptyPlaceholderWithMarkdown(
        in tabID: UUID? = nil,
        session markdownSession: MarkdownResourceSession,
        associatedPDFURL: URL? = nil
    ) -> PaneID? {
        let targetTab = tabID.flatMap { sessions[$0] } ?? activeTab
        guard targetTab.isEmptyPlaceholderTab else { return nil }

        let paneID = PaneID()
        markdownPool.register(markdownSession, for: paneID)
        guard let replacedPaneID = targetTab.replaceEmptyPlaceholderWithMarkdown(
            resourceSession: markdownSession,
            associatedPDFURL: associatedPDFURL,
            paneID: paneID
        ) else {
            markdownPool.release(session: markdownSession, for: paneID)
            return nil
        }
        objectWillChange.send()
        return replacedPaneID
    }

    /// Creates a new Markdown document registered in `markdownPool` and opens it
    /// in a split, empty placeholder tab, or new tab fallback.
    @discardableResult
    func createMarkdownNote(
        at url: URL,
        initialContent: String,
        associatedPDFURL: URL? = nil,
        in tabID: UUID? = nil,
        adjacentTo targetPaneID: PaneID? = nil,
        direction: LayoutInsertionDirection = .right,
        availableSize: CGSize? = nil
    ) -> Result<(tabID: UUID, paneID: PaneID), MarkdownLoadError> {
        let seedPaneID = PaneID()
        let createdSession: MarkdownResourceSession
        switch markdownPool.create(at: url, initialContent: initialContent, for: seedPaneID) {
        case let .success(created):
            createdSession = created
        case let .failure(error):
            return .failure(error)
        }

        let targetTab = tabID.flatMap { sessions[$0] } ?? activeTab

        if targetTab.hasLoadedContent,
           case let .success(splitPaneID) = openMarkdownSessionInSplit(
               session: createdSession,
               associatedPDFURL: associatedPDFURL,
               in: targetTab.id,
               adjacentTo: targetPaneID ?? targetTab.activePaneID,
               direction: direction,
               availableSize: availableSize
           ) {
            createdSession.releaseLease(for: seedPaneID)
            return .success((targetTab.id, splitPaneID))
        }

        if targetTab.isEmptyPlaceholderTab,
           let replacedPaneID = replaceEmptyPlaceholderWithMarkdown(
               in: targetTab.id,
               session: createdSession,
               associatedPDFURL: associatedPDFURL
           ) {
            createdSession.releaseLease(for: seedPaneID)
            return .success((targetTab.id, replacedPaneID))
        }

        let opened = openMarkdownInNewTab(
            session: createdSession,
            associatedPDFURL: associatedPDFURL
        )
        createdSession.releaseLease(for: seedPaneID)
        return .success(opened)
    }

    @discardableResult
    func saveMarkdownAs(
        _ session: MarkdownResourceSession,
        to destination: URL,
        overwrite: Bool = false
    ) -> SaveOutcome {
        markdownPool.saveAs(session, to: destination, overwrite: overwrite)
    }

    /// Resolves the target Markdown pane in `tabID` when citing a PDF at `pdfURL`.
    ///
    /// Priority:
    /// 1. Open Markdown pane matching the PDF's `PaperNoteAssociation`. If an
    ///    association exists for `pdfURL` but that note is not open in `tabID`,
    ///    returns `nil` rather than writing into another paper's note.
    /// 2. Open Markdown pane whose `associatedPDFURL` matches `pdfURL`.
    /// 3. Unassociated Markdown pane in `tabID`.
    func citationTargetMarkdownPane(
        forPDF pdfURL: URL?,
        in tabID: UUID? = nil
    ) -> MarkdownPaneSession? {
        guard let targetTab = sessions[tabID ?? activeTabID] else { return nil }

        var orderedPanes: [MarkdownPaneSession] = []
        if let activeMD = targetTab.activeMarkdownPaneSession {
            orderedPanes.append(activeMD)
        }
        for leafID in targetTab.layoutTree.leafIDs {
            if case let .markdown(mdPane) = targetTab.paneEntries[leafID],
               mdPane.id != targetTab.activePaneID {
                orderedPanes.append(mdPane)
            }
        }
        guard !orderedPanes.isEmpty else { return nil }

        let pdfCanonical = pdfURL?.resolvingSymlinksInPath().standardizedFileURL

        if let pdfURL, let pdfCanonical {
            if let association = noteAssociationStore.association(forPDF: pdfURL) {
                let resolved = noteAssociationStore.resolveAssociation(association)
                let expectedURL: URL
                if case let .resolved(resolvedURL, _) = resolved.markdownResolution {
                    expectedURL = resolvedURL
                } else {
                    expectedURL = association.markdownURL
                }
                let expectedCanonical = expectedURL.resolvingSymlinksInPath().standardizedFileURL
                return orderedPanes.first { mdPane in
                    mdPane.resourceSession.fileURL?
                        .resolvingSymlinksInPath()
                        .standardizedFileURL == expectedCanonical
                }
            }

            if let matchingByPaneAssociation = orderedPanes.first(where: { mdPane in
                mdPane.paneModel.associatedPDFURL?
                    .resolvingSymlinksInPath()
                    .standardizedFileURL == pdfCanonical
            }) {
                return matchingByPaneAssociation
            }
        }

        return orderedPanes.first { mdPane in
            guard mdPane.paneModel.associatedPDFURL == nil else { return false }
            guard let mdURL = mdPane.resourceSession.fileURL else { return true }
            let mdCanonical = mdURL.resolvingSymlinksInPath().standardizedFileURL
            let linkedToDifferentPDF = noteAssociationStore.associations.contains { assoc in
                let assocMDCanonical = assoc.markdownURL.resolvingSymlinksInPath().standardizedFileURL
                let assocPDFCanonical = assoc.pdfURL.resolvingSymlinksInPath().standardizedFileURL
                return assocMDCanonical == mdCanonical && assocPDFCanonical != pdfCanonical
            }
            return !linkedToDifferentPDF
        }
    }

    /// Resolves the companion loaded PDF pane in `tabID` for `mdSession`.
    ///
    /// When `mdSession` has a persisted `PaperNoteAssociation` or explicit
    /// `associatedPDFURL`, citations strictly target that PDF and return `nil`
    /// if it is not open in `tabID`, rather than citing an unrelated PDF. Only
    /// unassociated standalone Markdown panes fall back to `primaryPDFPaneSession`.
    func companionPDFPane(
        for mdSession: MarkdownPaneSession,
        in tabID: UUID? = nil
    ) -> PDFPaneSession? {
        guard let targetTab = sessions[tabID ?? activeTabID] else { return nil }

        func matchingLoadedPDF(for targetPDFURL: URL) -> PDFPaneSession? {
            let targetCanonical = targetPDFURL.resolvingSymlinksInPath().standardizedFileURL
            if let activePDF = targetTab.primaryPDFPaneSession,
               activePDF.resourceSession.isLoaded,
               activePDF.resourceSession.fileURL?.resolvingSymlinksInPath().standardizedFileURL == targetCanonical {
                return activePDF
            }
            for leafID in targetTab.layoutTree.leafIDs {
                if case let .pdf(pdfPane) = targetTab.paneEntries[leafID],
                   pdfPane.resourceSession.isLoaded,
                   pdfPane.resourceSession.fileURL?.resolvingSymlinksInPath().standardizedFileURL == targetCanonical {
                    return pdfPane
                }
            }
            return nil
        }

        if let mdURL = mdSession.resourceSession.fileURL {
            let mdCanonical = mdURL.resolvingSymlinksInPath().standardizedFileURL
            if let assoc = noteAssociationStore.associations.first(where: {
                $0.markdownURL.resolvingSymlinksInPath().standardizedFileURL == mdCanonical
            }) {
                return matchingLoadedPDF(for: assoc.pdfURL)
            }
        }

        if let associatedPDF = mdSession.paneModel.associatedPDFURL {
            return matchingLoadedPDF(for: associatedPDF)
        }

        if let fallback = targetTab.primaryPDFPaneSession, fallback.resourceSession.isLoaded {
            return fallback
        }
        return nil
    }

    func canInsertCitation(into mdSession: MarkdownPaneSession) -> Bool {
        mdSession.resourceSession.isLoaded
            && !mdSession.resourceSession.isReadOnlyAtOpen
            && mdSession.paneModel.configuration.isEditable
    }

    @discardableResult
    func insertCitationText(_ citation: String, into mdSession: MarkdownPaneSession) -> Bool {
        guard canInsertCitation(into: mdSession) else { return false }
        let controller = mdSession.paneModel.editorController
        _ = controller.focus()
        if controller.insertText(citation) {
            return true
        }
        let separator = mdSession.resourceSession.content.isEmpty
            || mdSession.resourceSession.content.hasSuffix("\n") ? "" : "\n"
        let updated = mdSession.resourceSession.content + separator + citation
        mdSession.resourceSession.updateContent(updated, from: mdSession.id)
        return true
    }

    /// Opens an already-created `MarkdownResourceSession` in a new tab (used when
    /// split creation cannot fit in the current tab).
    @discardableResult
    func openMarkdownInNewTab(
        session markdownSession: MarkdownResourceSession,
        associatedPDFURL: URL? = nil
    ) -> (tabID: UUID, paneID: PaneID) {
        let paneID = PaneID()
        markdownPool.register(markdownSession, for: paneID)
        let newTab = WorkspaceTabSession(
            markdownResourceSession: markdownSession,
            associatedPDFURL: associatedPDFURL,
            initialPaneID: paneID
        )
        _ = state.insert(WorkspaceTabIdentity(id: newTab.id, paneID: paneID.rawValue))
        sessions[newTab.id] = newTab
        observeTabSession(newTab)
        objectWillChange.send()
        return (newTab.id, paneID)
    }

    /// The last tab belongs to the native window close path. This method only
    /// removes a tab after its draft and document changes have been resolved.
    ///
    /// Only resources losing their final Pane are required to be clean: a
    /// resource still leased from another tab keeps its dirty state, pending
    /// autosave, and undo history for the remaining panes.
    @discardableResult
    func closeTab(tabID: UUID) -> Bool {
        guard let session = sessions[tabID],
              !session.hasUncommittedChanges,
              !resourceSessionsLosingFinalPane(in: tabID).contains(where: { $0.hasUnsavedChanges }),
              !markdownResourceSessionsLosingFinalPane(in: tabID).contains(where: { $0.hasUnsavedChanges }),
              state.tabs.count > 1,
              state.close(tabID: tabID) != nil
        else { return false }

        sessions[tabID] = nil
        tabObservingCancellables.removeValue(forKey: tabID)
        session.cancelAllPaneObserving()
        for paneSession in session.paneSessions.values {
            paneSession.paneModel.close()
        }
        for mdSession in session.markdownPaneSessions.values {
            mdSession.paneModel.close()
        }
        for resourceSession in session.uniqueResourceSessions {
            if resourceSession.activeLeaseCount == 0 {
                resourceSession.close()
            }
        }
        for mdResourceSession in session.uniqueMarkdownResourceSessions {
            if mdResourceSession.activeLeaseCount == 0 {
                mdResourceSession.close()
            }
        }
        objectWillChange.send()
        return true
    }

    @discardableResult
    func discardDraft(tabID: UUID) -> Bool {
        guard let session = sessions[tabID] else { return false }
        for paneSession in session.paneSessions.values {
            paneSession.paneModel.noteComposerStore.end()
        }
        return true
    }

    @discardableResult
    func discardDocumentChanges(tabID: UUID) -> Bool {
        guard sessions[tabID] != nil else { return false }
        // "Don't Save" resolves the documents this tab is the final reference
        // for. A shared resource is still owned by panes in other tabs, so its
        // dirty state, pending autosave, and undo history stay intact.
        for resourceSession in resourceSessionsLosingFinalPane(in: tabID) {
            resourceSession.abandonUnsavedChanges()
        }
        for mdResourceSession in markdownResourceSessionsLosingFinalPane(in: tabID) {
            mdResourceSession.discardUnsavedChanges()
        }
        return true
    }

    func discardPaneChanges(tabID: UUID? = nil, paneID: PaneID) {
        let targetTabID = tabID ?? activeTabID
        guard let session = sessions[targetTabID],
              let entry = session.paneEntry(for: paneID)
        else { return }
        switch entry {
        case let .pdf(pdfSession):
            pdfSession.paneModel.noteComposerStore.end()
        case let .markdown(mdSession):
            if mdSession.resourceSession.activeLeaseCount <= 1 {
                mdSession.resourceSession.discardUnsavedChanges()
            }
        }
    }

    var unsavedWork: UnsavedWork {
        synchronizeRevisions()
        return UnsavedWork(
            documentRevision: documentRevision,
            draftRevision: draftRevision,
            documentHasChanges: tabs.contains(where: { $0.hasUnsavedDocumentChanges }),
            draftHasChanges: tabs.contains(where: { $0.hasUncommittedChanges })
        )
    }

    func discardAllDrafts() {
        for tab in tabs {
            for paneSession in tab.paneSessions.values {
                paneSession.paneModel.noteComposerStore.end()
            }
        }
    }

    func discardAllDocumentChanges() {
        for tab in tabs {
            for resourceSession in tab.uniqueResourceSessions {
                resourceSession.abandonUnsavedChanges()
            }
            for mdResourceSession in tab.uniqueMarkdownResourceSessions {
                mdResourceSession.discardUnsavedChanges()
            }
        }
    }

    func closeAllSessions() {
        for session in sessions.values {
            session.cancelAllPaneObserving()
            for paneSession in session.paneSessions.values {
                paneSession.paneModel.close()
            }
            for mdSession in session.markdownPaneSessions.values {
                mdSession.paneModel.close()
            }
            for resourceSession in session.uniqueResourceSessions {
                resourceSession.close()
            }
            for mdResourceSession in session.uniqueMarkdownResourceSessions {
                mdResourceSession.close()
            }
        }
        tabObservingCancellables.removeAll()
    }

    private func makeSession() -> WorkspaceTabSession {
        WorkspaceTabSession(model: modelFactory())
    }

    private func observeTabSession(_ session: WorkspaceTabSession) {
        tabObservingCancellables[session.id] = session.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    private func synchronizeRevisions() {
        var currentDocuments: [UUID: Int] = [:]
        var currentDrafts: [UUID: Int] = [:]
        for tab in tabs {
            let pdfRev = tab.uniqueResourceSessions.map(\.editRevision).reduce(0, +)
            let mdRev = tab.uniqueMarkdownResourceSessions.map(\.editRevision).reduce(0, +)
            let draftRev = tab.paneSessions.values.map(\.paneModel.noteComposerStore.revision).reduce(0, +)
            currentDocuments[tab.id] = pdfRev &+ mdRev
            currentDrafts[tab.id] = draftRev
        }
        if currentDocuments != lastDocumentRevisions {
            documentRevision &+= 1
            lastDocumentRevisions = currentDocuments
        }
        if currentDrafts != lastDraftRevisions {
            draftRevision &+= 1
            lastDraftRevisions = currentDrafts
        }
    }
}
