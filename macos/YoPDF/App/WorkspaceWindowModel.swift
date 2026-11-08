import Combine
import Foundation
import YoPDFCore

@MainActor
final class WorkspaceTabSession: Identifiable {
    let id: UUID
    let paneID: UUID
    let model: PDFDocumentModel
    let composerStore: NoteComposerStore
    let searchSession: PDFSearchSession
    let navigationState: ReaderNavigationState

    init(
        identity: WorkspaceTabIdentity = WorkspaceTabIdentity(),
        model: PDFDocumentModel
    ) {
        id = identity.id
        paneID = identity.paneID
        self.model = model
        composerStore = NoteComposerStore()
        searchSession = PDFSearchSession()
        navigationState = ReaderNavigationState()
    }

    var title: String {
        model.fileURL?.lastPathComponent ?? "New Workspace"
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

    init(modelFactory: @escaping @MainActor () -> PDFDocumentModel) {
        let firstIdentity = WorkspaceTabIdentity()
        self.modelFactory = modelFactory
        state = WorkspaceState(initialTab: firstIdentity)
        sessions = [
            firstIdentity.id: WorkspaceTabSession(
                identity: firstIdentity,
                model: modelFactory()
            )
        ]
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

    func session(tabID: UUID) -> WorkspaceTabSession? {
        sessions[tabID]
    }

    func closeTabPrompt(tabID: UUID) -> ReaderPrompt? {
        guard let session = sessions[tabID] else { return nil }
        return ReaderPromptPolicy.prompt(
            for: .closeTab,
            draftHasChanges: session.composerStore.hasUncommittedChanges,
            documentHasChanges: session.model.hasUnsavedChanges
        )
    }

    func activate(tabID: UUID) {
        guard state.activate(tabID: tabID) else { return }
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
            $0.model.fileURL?.standardizedFileURL == url.standardizedFileURL
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
            candidate.model.close()
            return .failed(error)
        }

        _ = state.insert(WorkspaceTabIdentity(id: candidate.id, paneID: candidate.paneID))
        sessions[candidate.id] = candidate
        return .opened(tabID: candidate.id)
    }

    /// The last tab belongs to the native window close path. This method only
    /// removes a tab after its draft and PDF changes have been resolved.
    @discardableResult
    func closeTab(tabID: UUID) -> Bool {
        guard let session = sessions[tabID],
              !session.composerStore.hasUncommittedChanges,
              !session.model.hasUnsavedChanges,
              state.tabs.count > 1,
              state.close(tabID: tabID) != nil
        else { return false }

        sessions[tabID] = nil
        session.searchSession.clear()
        session.model.close()
        objectWillChange.send()
        return true
    }

    @discardableResult
    func discardDraft(tabID: UUID) -> Bool {
        guard let session = sessions[tabID] else { return false }
        session.composerStore.end()
        return true
    }

    @discardableResult
    func discardDocumentChanges(tabID: UUID) -> Bool {
        guard let session = sessions[tabID] else { return false }
        session.model.abandonUnsavedChanges()
        return true
    }

    var unsavedWork: UnsavedWork {
        synchronizeRevisions()
        return UnsavedWork(
            documentRevision: documentRevision,
            draftRevision: draftRevision,
            documentHasChanges: tabs.contains(where: { $0.model.hasUnsavedChanges }),
            draftHasChanges: tabs.contains(where: { $0.composerStore.hasUncommittedChanges })
        )
    }

    func discardAllDrafts() {
        tabs.forEach { $0.composerStore.end() }
    }

    func discardAllDocumentChanges() {
        tabs.forEach { $0.model.abandonUnsavedChanges() }
    }

    func closeAllSessions() {
        for session in sessions.values {
            session.composerStore.end()
            session.searchSession.clear()
            session.model.close()
        }
    }

    private func makeSession() -> WorkspaceTabSession {
        WorkspaceTabSession(model: modelFactory())
    }

    private func synchronizeRevisions() {
        let currentDocuments = Dictionary(
            uniqueKeysWithValues: tabs.map { ($0.id, $0.model.editRevision) }
        )
        let currentDrafts = Dictionary(
            uniqueKeysWithValues: tabs.map { ($0.id, $0.composerStore.revision) }
        )
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
