import Combine
import Foundation
import YoPDFCore

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

@MainActor
final class WorkspaceTabSession: Identifiable, ObservableObject {
    let id: UUID
    @Published var layoutTree: WorkspaceLayoutTree
    @Published var activePaneID: PaneID
    private(set) var paneSessions: [PaneID: PDFPaneSession]
    let navigationState: ReaderNavigationState

    private var documentModels: [PaneID: PDFDocumentModel] = [:]
    private var cancellables = Set<AnyCancellable>()

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
        paneSessions = [initialPaneID: initialSession]
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
        self.paneSessions = [initialPaneID: initialSession]
        self.navigationState = ReaderNavigationState()

        setupObserving(for: initialSession)
        setupNavigationObserving()
    }

    // MARK: - Active Pane Accessors

    var activePaneSession: PDFPaneSession? {
        paneSessions[activePaneID] ?? paneSessions.values.first
    }

    var paneID: UUID {
        activePaneID.rawValue
    }

    var model: PDFDocumentModel {
        if let session = activePaneSession {
            return model(for: session)
        }
        fatalError("WorkspaceTabSession must have at least one pane session.")
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
        guard let session = paneSessions[paneID] else { return nil }
        return model(for: session)
    }

    var composerStore: NoteComposerStore {
        activePaneSession?.paneModel.noteComposerStore ?? NoteComposerStore()
    }

    var searchSession: PDFSearchSession {
        activePaneSession?.paneModel.searchSession ?? PDFSearchSession()
    }

    /// Tab label: the document's file name, or the short placeholder for an
    /// empty workspace. "New Workspace" was long enough to crowd the tab strip
    /// next to real file names, so the placeholder is "New".
    var title: String {
        activePaneSession?.resourceSession.fileURL?.lastPathComponent ?? "New"
    }

    // MARK: - Multi-Pane Mutations

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

    var hasUncommittedChanges: Bool {
        paneSessions.values.contains { $0.paneModel.noteComposerStore.hasUncommittedChanges }
    }

    var hasUnsavedDocumentChanges: Bool {
        uniqueResourceSessions.contains { $0.hasUnsavedChanges }
    }

    /// Resolves and commits uncommitted drafts across all pane sessions in this tab.
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
        guard paneSessions[targetID] != nil else { return false }
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
        guard let targetSession = paneSessions[targetID] else {
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

        // New pane shares target's resourceSession
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
        paneSessions[newPaneID] = newSession
        activePaneID = newPaneID
        setupObserving(for: newSession)
        objectWillChange.send()
        return newPaneID
    }

    @discardableResult
    func closePane(_ paneID: PaneID) throws -> Bool {
        guard paneSessions.count > 1 else {
            throw LayoutMutationError.cannotCloseOnlyPane
        }
        guard let sessionToClose = paneSessions[paneID] else {
            throw LayoutMutationError.targetPaneNotFound(paneID)
        }
        // Direct close of a dirty pane cannot silently discard its draft
        guard !sessionToClose.paneModel.noteComposerStore.hasUncommittedChanges else {
            return false
        }

        let newTree = try layoutTree.removing(paneID)
        layoutTree = newTree

        sessionToClose.paneModel.close()
        paneSessions.removeValue(forKey: paneID)
        documentModels.removeValue(forKey: paneID)

        if activePaneID == paneID {
            if let first = layoutTree.leafIDs.first {
                activePaneID = first
            }
        }
        objectWillChange.send()
        return true
    }

    @discardableResult
    func detachPaneSession(_ paneID: PaneID) -> PDFPaneSession? {
        guard let session = paneSessions[paneID] else { return nil }
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
        paneSessions.removeValue(forKey: paneID)
        documentModels.removeValue(forKey: paneID)
        objectWillChange.send()
        return session
    }

    func attachTransferredPaneSession(_ session: PDFPaneSession, newLayoutTree: WorkspaceLayoutTree) {
        layoutTree = newLayoutTree
        paneSessions[session.id] = session
        activePaneID = session.id
        setupObserving(for: session)
        objectWillChange.send()
    }

    /// Returns an error if replacing `targetPaneID` would silently discard an uncommitted
    /// note draft or the sole surviving lease on a dirty `PDFResourceSession`.
    func replacementError(
        for targetPaneID: PaneID,
        incomingResourceSession: PDFResourceSession? = nil
    ) -> PaneReplaceError? {
        guard let targetSession = paneSessions[targetPaneID] else { return nil }
        if targetSession.paneModel.noteComposerStore.hasUncommittedChanges {
            return .targetHasUncommittedDraft
        }
        let targetResource = targetSession.resourceSession
        if targetResource.hasUnsavedChanges {
            let sameResourceReused = (incomingResourceSession === targetResource)
            let otherLeaseExists = !targetResource.activePaneIDs.subtracting([targetPaneID]).isEmpty
            if !sameResourceReused && !otherLeaseExists {
                return .targetHasUnsavedDocumentChanges
            }
        }
        return nil
    }

    func canReplacePane(
        _ targetPaneID: PaneID,
        incomingResourceSession: PDFResourceSession? = nil
    ) -> (isValid: Bool, feedback: String) {
        guard paneSessions[targetPaneID] != nil else {
            return (false, "Invalid drop target")
        }
        if let error = replacementError(for: targetPaneID, incomingResourceSession: incomingResourceSession) {
            return (false, error.localizedDescription)
        }
        return (true, "")
    }

    private func releaseClosedPaneSession(
        _ paneID: PaneID,
        preservingResource incomingResource: PDFResourceSession? = nil
    ) {
        guard let oldSession = paneSessions.removeValue(forKey: paneID) else { return }
        documentModels.removeValue(forKey: paneID)
        let oldResource = oldSession.resourceSession
        oldSession.paneModel.close()
        if oldResource !== incomingResource && oldResource.activeLeaseCount == 0 {
            oldResource.close()
        }
    }

    func replacePaneSession(
        _ targetPaneID: PaneID,
        with incomingSession: PDFPaneSession,
        newLayoutTree: WorkspaceLayoutTree
    ) {
        releaseClosedPaneSession(targetPaneID, preservingResource: incomingSession.resourceSession)
        layoutTree = newLayoutTree
        paneSessions[incomingSession.id] = incomingSession
        activePaneID = incomingSession.id
        setupObserving(for: incomingSession)
        objectWillChange.send()
    }

    func movePaneWithinTabReplacing(
        paneID: PaneID,
        replacing targetPaneID: PaneID
    ) throws {
        guard paneID != targetPaneID else {
            throw LayoutMutationError.duplicatePaneID(paneID)
        }
        guard let sourceSession = paneSessions[paneID] else {
            throw LayoutMutationError.targetPaneNotFound(paneID)
        }
        guard paneSessions[targetPaneID] != nil else {
            throw LayoutMutationError.targetPaneNotFound(targetPaneID)
        }
        if let error = replacementError(for: targetPaneID, incomingResourceSession: sourceSession.resourceSession) {
            throw error
        }

        let newTree = try layoutTree.moving(paneID, replacing: targetPaneID)
        releaseClosedPaneSession(targetPaneID, preservingResource: sourceSession.resourceSession)
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
        session.paneModel.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        session.resourceSession.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
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

/// Stable owner of the PDF runtime sessions inside one macOS window.
///
/// The value state carries tab and pane identity; this object keeps the live
/// PDFKit models, note drafts, and find sessions alive across SwiftUI updates.
@MainActor
final class WorkspaceWindowModel: ObservableObject {

    @Published private(set) var state: WorkspaceState
    private var sessions: [UUID: WorkspaceTabSession]
    private let modelFactory: @MainActor () -> PDFDocumentModel
    private var lastDocumentRevisions: [UUID: Int] = [:]
    private var lastDraftRevisions: [UUID: Int] = [:]
    private var documentRevision = 0
    private var draftRevision = 0
    private var tabObservingCancellables: [UUID: AnyCancellable] = [:]

    init(modelFactory: @escaping @MainActor () -> PDFDocumentModel) {
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
        let tabPaneIDs = Set(session.paneSessions.keys)
        return session.uniqueResourceSessions.filter { $0.activePaneIDs.isSubset(of: tabPaneIDs) }
    }

    func closeTabPrompt(tabID: UUID) -> ReaderPrompt? {
        guard let session = sessions[tabID] else { return nil }
        return ReaderPromptPolicy.prompt(
            for: .closeTab,
            draftHasChanges: session.hasUncommittedChanges,
            documentHasChanges: resourceSessionsLosingFinalPane(in: tabID).contains { $0.hasUnsavedChanges }
        )
    }

    func closePanePrompt(tabID: UUID? = nil, paneID: PaneID? = nil) -> ReaderPrompt? {
        let targetTabID = tabID ?? activeTabID
        guard let session = sessions[targetTabID] else { return nil }
        let targetPaneID = paneID ?? session.activePaneID
        guard let paneSession = session.paneSessions[targetPaneID] else { return nil }
        return ReaderPromptPolicy.prompt(
            for: .closeTab,
            draftHasChanges: paneSession.paneModel.noteComposerStore.hasUncommittedChanges,
            documentHasChanges: false
        )
    }

    func activate(tabID: UUID) {
        guard state.activate(tabID: tabID) else { return }
    }

    func activate(paneID: PaneID, in tabID: UUID? = nil) {
        let targetTabID = tabID ?? activeTabID
        guard let session = sessions[targetTabID],
              session.paneSessions[paneID] != nil else { return }
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

    /// Safely closes a tab that has had all its pane sessions transferred out.
    /// Does NOT close any PDFResourceSession or PDFPaneModel instances since they were transferred.
    func closeEmptyTabAfterTransfer(_ tabID: UUID) {
        guard let session = sessions[tabID], session.paneSessions.isEmpty else { return }
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
        guard sourceTab.paneSessions[paneID] != nil else {
            throw LayoutMutationError.targetPaneNotFound(paneID)
        }
        guard destinationTab.paneSessions[targetPaneID] != nil else {
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
        guard let transferredSession = sourceTab.detachPaneSession(paneID) else {
            throw LayoutMutationError.targetPaneNotFound(paneID)
        }

        if isSourceTabEmptying {
            closeEmptyTabAfterTransfer(sourceTabID)
        }

        // Attach to destination
        destinationTab.attachTransferredPaneSession(transferredSession, newLayoutTree: newTree)
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
              let sourceSession = sourceTab.paneSessions[paneID] else {
            throw LayoutMutationError.targetPaneNotFound(paneID)
        }
        guard let destinationTab = sessions[destinationTabID],
              destinationTab.paneSessions[targetPaneID] != nil else {
            throw LayoutMutationError.targetPaneNotFound(targetPaneID)
        }

        if let error = destinationTab.replacementError(
            for: targetPaneID,
            incomingResourceSession: sourceSession.resourceSession
        ) {
            throw error
        }

        let newTree = try destinationTab.layoutTree.replacing(targetPaneID, with: paneID)
        let isSourceTabEmptying = (sourceTab.layoutTree.paneCount <= 1)

        guard let transferredSession = sourceTab.detachPaneSession(paneID) else {
            throw LayoutMutationError.targetPaneNotFound(paneID)
        }

        if isSourceTabEmptying {
            closeEmptyTabAfterTransfer(sourceTabID)
        }

        destinationTab.replacePaneSession(targetPaneID, with: transferredSession, newLayoutTree: newTree)
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

        destinationTab.attachTransferredPaneSession(newSession, newLayoutTree: candidateTree)
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
              destinationTab.paneSessions[targetPaneID] != nil else {
            return .failure(LayoutMutationError.targetPaneNotFound(targetPaneID))
        }

        // 1. Check unsaved drafts or orphaned dirty document edits before opening anything
        let existing = findResourceSession(for: url)
        if let error = destinationTab.replacementError(for: targetPaneID, incomingResourceSession: existing) {
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

        destinationTab.replacePaneSession(targetPaneID, with: newSession, newLayoutTree: candidateTree)
        objectWillChange.send()
        return .success(candidatePaneID)
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
        guard let paneSession = session.paneSessions[targetPaneID],
              !paneSession.paneModel.noteComposerStore.hasUncommittedChanges else {
            return false
        }
        let closed = try session.closePane(targetPaneID)
        if closed {
            objectWillChange.send()
        }
        return closed
    }

    /// Commits a tab strip drag. The ordering rule lives in `WorkspaceState`;
    /// this republishes the result so the tab strip and the reader's active
    /// model stay in sync without touching any PDF session.\
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

    /// Opens into the active empty tab, or adds a new tab after a successful
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
            return .activatedExisting(tabID: existing.id)
        }

        let current = activeTab
        if !current.model.isLoaded {
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

    /// The last tab belongs to the native window close path. This method only
    /// removes a tab after its draft and PDF changes have been resolved.
    ///
    /// Only resources losing their final Pane are required to be clean: a
    /// resource still leased from another tab keeps its dirty state, pending
    /// autosave, and undo history for the remaining panes.
    @discardableResult
    func closeTab(tabID: UUID) -> Bool {
        guard let session = sessions[tabID],
              !session.hasUncommittedChanges,
              !resourceSessionsLosingFinalPane(in: tabID).contains(where: { $0.hasUnsavedChanges }),
              state.tabs.count > 1,
              state.close(tabID: tabID) != nil
        else { return false }

        sessions[tabID] = nil
        tabObservingCancellables.removeValue(forKey: tabID)
        for paneSession in session.paneSessions.values {
            paneSession.paneModel.close()
        }
        for resourceSession in session.uniqueResourceSessions {
            if resourceSession.activeLeaseCount == 0 {
                resourceSession.close()
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
        return true
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
        }
    }

    func closeAllSessions() {
        for session in sessions.values {
            for paneSession in session.paneSessions.values {
                paneSession.paneModel.close()
            }
            for resourceSession in session.uniqueResourceSessions {
                resourceSession.close()
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
            let docRev = tab.uniqueResourceSessions.map(\.editRevision).reduce(0, +)
            let draftRev = tab.paneSessions.values.map(\.paneModel.noteComposerStore.revision).reduce(0, +)
            currentDocuments[tab.id] = docRev
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
