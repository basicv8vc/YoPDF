import Combine
import Foundation
import YoPDFCore

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

    var title: String {
        activePaneSession?.resourceSession.fileURL?.lastPathComponent ?? "New Workspace"
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
        guard layoutTree.paneCount < policy.maxPanes else { return false }

        if let availableSize {
            let existingFrames = layoutTree.paneFrames(in: availableSize, policy: policy)
            guard let targetFrame = existingFrames[targetID] else { return false }
            switch direction.axis {
            case .horizontal:
                let requiredWidth = policy.minimumLeafWidth * 2 + policy.dividerThickness
                if targetFrame.width < requiredWidth || targetFrame.height < policy.minimumLeafHeight {
                    return false
                }
            case .vertical:
                let requiredHeight = policy.minimumLeafHeight * 2 + policy.dividerThickness
                if targetFrame.height < requiredHeight || targetFrame.width < policy.minimumLeafWidth {
                    return false
                }
            }
        }
        return true
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

    func closeTabPrompt(tabID: UUID) -> ReaderPrompt? {
        guard let session = sessions[tabID] else { return nil }
        return ReaderPromptPolicy.prompt(
            for: .closeTab,
            draftHasChanges: session.hasUncommittedChanges,
            documentHasChanges: session.hasUnsavedDocumentChanges
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

    /// Opens a local PDF file from Finder into a split adjacent to a target pane.
    /// Validates file and opens before committing any layout mutation.
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
        guard destinationTab.canSplit(paneID: targetPaneID, direction: direction, policy: policy, availableSize: availableSize) else {
            return .failure(LayoutMutationError.insufficientSpace(required: policy.minimumLeafWidth * 2, available: 0))
        }
        guard destinationTab.layoutTree.paneCount < policy.maxPanes else {
            return .failure(LayoutMutationError.maximumPaneLimitReached(limit: policy.maxPanes))
        }

        // Reuse existing resourceSession if file is already open, or open fresh resourceSession
        let resourceSessionToUse: PDFResourceSession
        if let existing = findResourceSession(for: url) {
            resourceSessionToUse = existing
        } else {
            let newResource = PDFResourceSession()
            guard newResource.open(url: url) else {
                let error = newResource.lastError ?? .unreadable
                newResource.close()
                return .failure(error)
            }
            resourceSessionToUse = newResource
        }

        let newPaneID = PaneID()
        do {
            let newTree = try destinationTab.layoutTree.inserting(
                newPaneID,
                adjacentTo: targetPaneID,
                direction: direction,
                ratio: ratio,
                policy: policy,
                availableSize: availableSize
            )

            let newPaneModel = PDFPaneModel(id: newPaneID, resourceSession: resourceSessionToUse)
            let newSession = PDFPaneSession(
                paneID: newPaneID,
                paneModel: newPaneModel,
                resourceSession: resourceSessionToUse
            )

            destinationTab.attachTransferredPaneSession(newSession, newLayoutTree: newTree)
            objectWillChange.send()
            return .success(newPaneID)
        } catch {
            return .failure(error)
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
    @discardableResult
    func closeTab(tabID: UUID) -> Bool {
        guard let session = sessions[tabID],
              !session.hasUncommittedChanges,
              !session.hasUnsavedDocumentChanges,
              state.tabs.count > 1,
              state.close(tabID: tabID) != nil
        else { return false }

        sessions[tabID] = nil
        tabObservingCancellables.removeValue(forKey: tabID)
        for paneSession in session.paneSessions.values {
            paneSession.paneModel.close()
        }
        for resourceSession in session.uniqueResourceSessions {
            resourceSession.close()
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
        guard let session = sessions[tabID] else { return false }
        for resourceSession in session.uniqueResourceSessions {
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
