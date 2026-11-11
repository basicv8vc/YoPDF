import AppKit
import Foundation
import PDFKit

/// Shared document-level runtime authority for an open PDF file.
///
/// Owns the canonical `PDFDocument`, `fileURL`, security-scoped `DocumentSession`,
/// document-level dirty tracking and autosave debounce, markup undo/redo history,
/// annotation collections, and the `PDFSearchCoordinator` that serializes find
/// operations against the shared PDF.
///
/// Multiple `PDFPaneModel` instances can observe and interact with a single
/// `PDFResourceSession` without duplicating file leases or editable document state.
@MainActor
public final class PDFResourceSession: ObservableObject, Identifiable {

    public let id: UUID

    // MARK: - Document Identity & Core State

    @Published public private(set) var document: PDFDocument?
    @Published public private(set) var fileURL: URL?
    @Published public private(set) var title: String = ""
    @Published public private(set) var pageCount: Int = 0
    @Published public private(set) var lastError: PDFDocumentModel.LoadError?
    @Published public private(set) var loadGeneration: Int = 0

    // MARK: - File Session & Access Lease

    let store: DocumentStore
    public private(set) var documentSession: DocumentSession?
    let recentDocuments: RecentDocumentsStore?
    public let markupPreferences: MarkupColorPreferences

    // MARK: - Shared Annotations & Revision

    @Published public internal(set) var annotationRevision: Int = 0
    public internal(set) var changedAnnotationPageIndices: [Int] = []
    @Published public internal(set) var noteMarkers: [NoteMarker] = []
    @Published public internal(set) var canUndoMarkup: Bool = false
    @Published public internal(set) var canRedoMarkup: Bool = false
    var markupUndoStack: [MarkupEdit] = []
    var markupRedoStack: [MarkupEdit] = []

    // MARK: - Dirty Tracking & Autosave

    @Published public private(set) var hasUnsavedChanges: Bool = false
    @Published public internal(set) var autoSaveStatus: AutoSaveStatus = .idle
    @Published public internal(set) var autoSaveFailureRevision: Int = 0
    public internal(set) var lastAutoSaveOutcome: SaveOutcome?
    public private(set) var editRevision: Int = 0

    var autoSaveTask: Task<Void, Never>?
    var autoSaveGeneration: Int = 0
    var autoSaveWorkTask: Task<SaveOutcome, Never>?
    var autoSaveWorkGeneration: Int?
    var autoSaveWorkCompletion: AutoSaveWorkCompletion?
    var autoSavePauseDepth: Int = 0
    var autoSaveShouldResumeAfterPause: Bool = false
    public var autoSaveDebounceNanoseconds: UInt64 = 750_000_000
    var autoSaveSerializer: @Sendable (PDFDocumentSaveSnapshot) -> Data? = {
        PDFDocumentSaveSerializer.dataRepresentationPreservingShuaGroups(in: $0.document)
    }

    // MARK: - Search Coordinator

    public let searchCoordinator: PDFSearchCoordinator

    // MARK: - Pane Leases

    private var activeLeases: Set<PaneID> = []

    public init(
        id: UUID = UUID(),
        access: any SecurityScopeAccessing = SystemSecurityScopeAccess(),
        io: any DocumentStoreIO = SystemDocumentStoreIO(),
        markupPreferences: MarkupColorPreferences = .shared,
        recentDocuments: RecentDocumentsStore? = nil
    ) {
        self.id = id
        self.store = DocumentStore(access: access, io: io)
        self.markupPreferences = markupPreferences
        self.recentDocuments = recentDocuments
        self.searchCoordinator = PDFSearchCoordinator()
    }

    public var isLoaded: Bool { document != nil }
    public var activeLeaseCount: Int { activeLeases.count }
    public var activePaneIDs: Set<PaneID> { activeLeases }

    public func acquireLease(for paneID: PaneID) {
        activeLeases.insert(paneID)
    }

    public func releaseLease(for paneID: PaneID) {
        guard activeLeases.remove(paneID) != nil else { return }
        if activeLeases.isEmpty {
            close()
        }
    }

    public func dismissError() {
        lastError = nil
    }

    // MARK: - Opening

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

        let reopeningCurrentFile = fileURL?.standardizedFileURL == url.standardizedFileURL
        if reopeningCurrentFile {
            pauseAutoSave()
        }
        defer {
            if reopeningCurrentFile {
                resumeAutoSave()
            }
        }

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

        let hadAutoSaveInProgress =
            (autoSaveStatus == .pending || autoSaveStatus == .saving) && autoSaveTask != nil
        let scheduledAutoSaveGeneration = autoSaveGeneration
        let activeWorkMatchesSchedule = autoSaveWorkGeneration == scheduledAutoSaveGeneration
        let writeWasCancelledBeforeStart = cancelPendingAutoSave(
            cancelInFlightWork: discardingUnsavedChanges
        )
        let automaticWriteWasStarted = autoSaveWorkCompletion?.didStartWrite ?? false
        let completedAutoSaveOutcome = waitForAutoSaveWork()

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
                    restoreAutoSaveAfterFailedOpen(
                        wasScheduled: hadAutoSaveInProgress,
                        activeWorkMatchesSchedule: activeWorkMatchesSchedule,
                        writeWasCancelledBeforeStart: writeWasCancelledBeforeStart,
                        completedOutcome: completedAutoSaveOutcome
                    )
                    lastError = .couldNotRelinkRecentDocument
                    return false
                }
            } catch {
                candidate.close()
                restoreAutoSaveAfterFailedOpen(
                    wasScheduled: hadAutoSaveInProgress,
                    activeWorkMatchesSchedule: activeWorkMatchesSchedule,
                    writeWasCancelledBeforeStart: writeWasCancelledBeforeStart,
                    completedOutcome: completedAutoSaveOutcome
                )
                lastError = .couldNotRelinkRecentDocument
                return false
            }
        }

        let previous = documentSession
        documentSession = candidate
        previous?.close()

        apply(document: opened, fileURL: url)
        if recentDocument == nil, let recentDocuments, !recentDocuments.recordOpened(url) {
            NSLog("YoPDF could not save a recent-document bookmark for %@", url.lastPathComponent)
        }
        return true
    }

    public func close() {
        cancelPendingAutoSave(cancelInFlightWork: true)
        waitForAutoSaveWork()
        autoSavePauseDepth = 0
        autoSaveShouldResumeAfterPause = false
        searchCoordinator.cancelAll()
        documentSession?.close()
        documentSession = nil
        document = nil
        fileURL = nil
        title = ""
        pageCount = 0
        lastError = nil
        hasUnsavedChanges = false
        autoSaveStatus = .idle
        lastAutoSaveOutcome = nil
        editRevision &+= 1
        resetMarkupState()
        noteMarkers = []
        loadGeneration &+= 1
        activeLeases.removeAll()
    }

    func apply(document: PDFDocument, fileURL: URL?) {
        cancelPendingAutoSave()
        self.document = document
        self.fileURL = fileURL
        self.pageCount = document.pageCount
        self.lastError = nil
        self.hasUnsavedChanges = false
        self.autoSaveStatus = .idle
        self.lastAutoSaveOutcome = nil
        self.editRevision &+= 1
        resetMarkupState()
        refreshNoteMarkers()
        self.title = Self.resolvedTitle(for: document, fileURL: fileURL)
        self.loadGeneration &+= 1
        self.searchCoordinator.bindDocument(document)
    }

    func swapDocument(_ newDocument: PDFDocument) {
        self.document = newDocument
        self.pageCount = newDocument.pageCount
        resetMarkupState()
        changedAnnotationPageIndices = Array(0..<newDocument.pageCount)
        annotationRevision &+= 1
        refreshNoteMarkers()
        title = Self.resolvedTitle(for: newDocument, fileURL: fileURL)
        searchCoordinator.bindDocument(newDocument)
    }

    func adoptFileLocation(_ url: URL) {
        fileURL = url
        if let document {
            title = Self.resolvedTitle(for: document, fileURL: url)
        }
        if let recentDocuments, !recentDocuments.recordOpened(url) {
            NSLog("YoPDF could not save a recent-document bookmark for %@", url.lastPathComponent)
        }
    }

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
        if !preservingMarkupHistory {
            resetMarkupState()
        }
    }

    public func abandonUnsavedChanges() {
        cancelPendingAutoSave(cancelInFlightWork: true)
        waitForAutoSaveWork()
        markSaved()
    }

    func resetMarkupState() {
        markupUndoStack.removeAll()
        markupRedoStack.removeAll()
        canUndoMarkup = false
        canRedoMarkup = false
        changedAnnotationPageIndices = []
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

    static func loadError(from error: DocumentStoreError) -> PDFDocumentModel.LoadError {
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
            return .unreadable
        }
    }

    // MARK: - Saving & Persistence

    @discardableResult
    public func save() -> SaveOutcome {
        cancelPendingAutoSave(cancelInFlightWork: true)
        waitForAutoSaveWork()
        return save(preservingUndoHistory: true)
    }

    private func save(preservingUndoHistory: Bool) -> SaveOutcome {
        guard let document, let session = documentSession else { return .failed(.noDocument) }
        guard hasUnsavedChanges else { return .saved }
        guard let snapshot = document.copy() as? PDFDocument,
              let data = PDFDocumentSaveSerializer.dataRepresentationPreservingShuaGroups(in: snapshot) else {
            return .failed(.serializationFailed)
        }

        do {
            try session.save(data)
        } catch let error as DocumentStoreError {
            return resolveSaveFailure(
                error,
                session: session,
                preservingUndoHistory: preservingUndoHistory
            )
        } catch {
            return .failed(.store(.stagingFailed(error.localizedDescription)))
        }
        return finishWrite(preservingUndoHistory: preservingUndoHistory)
    }

    func scheduleAutoSave() {
        if autoSavePauseDepth > 0 {
            autoSaveShouldResumeAfterPause = true
            autoSaveTask?.cancel()
            autoSaveTask = nil
            autoSaveGeneration &+= 1
            autoSaveStatus = .pending
            lastAutoSaveOutcome = nil
            return
        }

        autoSaveTask?.cancel()
        autoSaveGeneration &+= 1
        let generation = autoSaveGeneration
        let scheduledRevision = editRevision
        autoSaveStatus = .pending
        lastAutoSaveOutcome = nil

        autoSaveTask = Task { [weak self] in
            do {
                guard let delay = self?.autoSaveDebounceNanoseconds else { return }
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            await self?.performAutomaticSave(
                generation: generation,
                scheduledRevision: scheduledRevision
            )
        }
    }

    func restoreAutoSaveAfterFailedOpen(
        wasScheduled: Bool,
        activeWorkMatchesSchedule: Bool,
        writeWasCancelledBeforeStart: Bool?,
        completedOutcome: SaveOutcome?
    ) {
        guard wasScheduled, document != nil else { return }

        if activeWorkMatchesSchedule, writeWasCancelledBeforeStart == false,
           let completedOutcome {
            if completedOutcome.editsAreOnDisk {
                markSaved(preservingMarkupHistory: true)
            }
            lastAutoSaveOutcome = completedOutcome
            if case .saved = completedOutcome {
                autoSaveStatus = .saved
            } else {
                autoSaveStatus = .failed(completedOutcome)
                autoSaveFailureRevision &+= 1
            }
            return
        }

        guard hasUnsavedChanges else { return }
        scheduleAutoSave()
    }

    public func withAutoSavePaused<T>(_ operation: () throws -> T) rethrows -> T {
        pauseAutoSave()
        defer { resumeAutoSave() }
        return try operation()
    }

    func pauseAutoSave() {
        autoSavePauseDepth += 1
        guard autoSavePauseDepth == 1 else { return }

        let hasScheduledSave = autoSaveStatus == .pending || autoSaveStatus == .saving
        guard hasScheduledSave else {
            autoSaveShouldResumeAfterPause = false
            return
        }

        let cancellationWon = autoSaveWorkCompletion?.cancelBeforeWrite()
        let writeAlreadyStarted = cancellationWon == false
        let currentAttemptHasStartedWriting = autoSaveStatus == .saving
            && autoSaveWorkGeneration == autoSaveGeneration
            && writeAlreadyStarted
        autoSaveShouldResumeAfterPause = hasUnsavedChanges && !currentAttemptHasStartedWriting
        guard !currentAttemptHasStartedWriting else { return }

        autoSaveGeneration &+= 1
        autoSaveTask?.cancel()
        autoSaveTask = nil
        if cancellationWon == true {
            autoSaveWorkTask?.cancel()
        }
        autoSaveStatus = .idle
    }

    func resumeAutoSave() {
        guard autoSavePauseDepth > 0 else { return }
        autoSavePauseDepth -= 1
        guard autoSavePauseDepth == 0 else { return }

        let shouldResume = autoSaveShouldResumeAfterPause
        autoSaveShouldResumeAfterPause = false
        guard shouldResume, hasUnsavedChanges else { return }
        if case .failed = autoSaveStatus { return }
        scheduleAutoSave()
    }

    private func performAutomaticSave(generation: Int, scheduledRevision: Int) async {
        guard autoSaveGeneration == generation,
              editRevision == scheduledRevision,
              hasUnsavedChanges
        else { return }

        autoSaveStatus = .saving

        if let previousWork = autoSaveWorkTask {
            let previousGeneration = autoSaveWorkGeneration
            _ = await previousWork.value
            clearAutoSaveWork(ifGeneration: previousGeneration)
        }

        guard autoSaveGeneration == generation,
              editRevision == scheduledRevision,
              hasUnsavedChanges,
              let document,
              let session = documentSession
        else { return }

        guard let documentCopy = document.copy() as? PDFDocument else {
            finishAutomaticSave(
                .failed(.serializationFailed),
                generation: generation,
                scheduledRevision: scheduledRevision,
                document: document,
                session: session
            )
            return
        }

        let snapshot = PDFDocumentSaveSnapshot(document: documentCopy)
        let serializer = autoSaveSerializer
        let pageCount = document.pageCount
        let completion = AutoSaveWorkCompletion()
        let worker = Task.detached(priority: .utility) {
            guard let data = serializer(snapshot) else {
                let outcome = SaveOutcome.failed(.serializationFailed)
                completion.complete(with: outcome)
                return outcome
            }
            guard completion.beginWriteUnlessCancelled() else {
                let outcome = SaveOutcome.failed(.sessionUnavailable)
                completion.complete(with: outcome)
                return outcome
            }
            let outcome = AutomaticSaveWorker.save(data, to: session, pageCount: pageCount)
            completion.complete(with: outcome)
            return outcome
        }

        autoSaveWorkTask = worker
        autoSaveWorkGeneration = generation
        autoSaveWorkCompletion = completion

        let outcome = await worker.value
        clearAutoSaveWork(ifGeneration: generation)
        finishAutomaticSave(
            outcome,
            generation: generation,
            scheduledRevision: scheduledRevision,
            document: document,
            session: session
        )
    }

    private func clearAutoSaveWork(ifGeneration generation: Int?) {
        guard let generation, autoSaveWorkGeneration == generation else { return }
        autoSaveWorkTask = nil
        autoSaveWorkGeneration = nil
        autoSaveWorkCompletion = nil
    }

    private func finishAutomaticSave(
        _ outcome: SaveOutcome,
        generation: Int,
        scheduledRevision: Int,
        document savedDocument: PDFDocument,
        session savedSession: DocumentSession
    ) {
        guard autoSaveGeneration == generation,
              editRevision == scheduledRevision,
              document === savedDocument,
              documentSession === savedSession,
              hasUnsavedChanges
        else { return }

        if outcome.editsAreOnDisk {
            markSaved(preservingMarkupHistory: true)
        }
        lastAutoSaveOutcome = outcome
        if case .saved = outcome {
            autoSaveStatus = .saved
        } else {
            autoSaveStatus = .failed(outcome)
            autoSaveFailureRevision &+= 1
        }
        autoSaveTask = nil
    }

    @discardableResult
    func cancelPendingAutoSave(cancelInFlightWork: Bool = false) -> Bool? {
        autoSaveGeneration &+= 1
        autoSaveTask?.cancel()
        autoSaveTask = nil
        var writeWasCancelledBeforeStart: Bool?
        if cancelInFlightWork {
            writeWasCancelledBeforeStart = autoSaveWorkCompletion?.cancelBeforeWrite()
            autoSaveWorkTask?.cancel()
        }
        if autoSaveStatus == .pending || autoSaveStatus == .saving {
            autoSaveStatus = .idle
        }
        return writeWasCancelledBeforeStart
    }

    @discardableResult
    func waitForAutoSaveWork() -> SaveOutcome? {
        guard let completion = autoSaveWorkCompletion else { return nil }
        completion.wait()
        let outcome = completion.outcome
        autoSaveWorkTask = nil
        autoSaveWorkGeneration = nil
        autoSaveWorkCompletion = nil
        return outcome
    }

    @discardableResult
    public func saveAs(to destination: URL, overwrite: Bool = false) -> SaveOutcome {
        cancelPendingAutoSave(cancelInFlightWork: true)
        waitForAutoSaveWork()
        guard let document, let session = documentSession else { return .failed(.noDocument) }
        guard let data = NoteService.dataRepresentationPreservingShuaGroups(in: document) else {
            return .failed(.serializationFailed)
        }

        do {
            let newSession = try session.saveAs(data, to: destination, overwrite: overwrite)
            let reloaded = reloadedDocument(at: destination)
            adoptFileLocation(destination)
            adoptSession(newSession)
            markSaved()
            guard let reloaded else {
                return .savedUnverified(
                    reason: "The copy was written, but it could not be reopened.",
                    editsOnDisk: true
                )
            }
            swapDocument(reloaded)
            return .saved
        } catch let error as DocumentStoreError {
            return resolveSaveAsFailure(error)
        } catch {
            return .failed(.store(.stagingFailed(error.localizedDescription)))
        }
    }

    private func finishWrite(preservingUndoHistory: Bool = false) -> SaveOutcome {
        markSaved(preservingMarkupHistory: preservingUndoHistory)
        let resyncFailure: String?
        if preservingUndoHistory {
            resyncFailure = verifyDocumentAfterWrite()
        } else {
            resyncFailure = resyncDocumentAfterWrite()
        }
        if let reason = resyncFailure {
            return .savedUnverified(reason: reason, editsOnDisk: true)
        }
        return .saved
    }

    private func resolveSaveFailure(
        _ error: DocumentStoreError,
        session: DocumentSession,
        preservingUndoHistory: Bool
    ) -> SaveOutcome {
        switch error {
        case let .committedButUnverified(_, reason):
            do {
                _ = try session.refresh()
                return finishWrite(preservingUndoHistory: preservingUndoHistory)
            } catch {
                let detail = (error as? DocumentStoreError)?.localizedDescription
                    ?? error.localizedDescription
                return .savedUnverified(reason: "\(reason) \(detail)", editsOnDisk: false)
            }
        case let .externalModificationDetected(change):
            return .conflict(.externalModificationDetected(change))
        case let .replacementStateUncertain(recovery):
            return uncertainOutcome(recovery)
        default:
            return .failed(.store(error))
        }
    }

    private func resolveSaveAsFailure(_ error: DocumentStoreError) -> SaveOutcome {
        switch error {
        case let .committedButUnverified(url, reason):
            if let reopened = try? store.open(url) {
                adoptSession(reopened)
                adoptFileLocation(url)
                return finishWrite()
            }
            return .savedUnverified(
                reason: "“\(url.lastPathComponent)” was written, but it could not be opened, "
                    + "so this window is still showing the original file. \(reason)",
                editsOnDisk: true
            )
        case let .externalModificationDetected(change):
            return .conflict(.externalModificationDetected(change))
        case let .replacementStateUncertain(recovery):
            return uncertainOutcome(recovery)
        default:
            return .failed(.store(error))
        }
    }

    private func uncertainOutcome(_ recovery: ReplacementRecovery) -> SaveOutcome {
        .uncertain(
            reason: DocumentStoreError.replacementStateUncertain(recovery).localizedDescription,
            recovery: recovery.recoverableURLs
        )
    }

    private func resyncDocumentAfterWrite() -> String? {
        guard let url = fileURL else { return "The document has no file location." }
        guard let reloaded = reloadedDocument(at: url) else {
            return "The file was written, but it could not be reopened."
        }
        swapDocument(reloaded)
        return nil
    }

    private func verifyDocumentAfterWrite() -> String? {
        guard let url = fileURL else { return "The document has no file location." }
        guard reloadedDocument(at: url) != nil else {
            return "The file was written, but it could not be reopened."
        }
        return nil
    }

    private func reloadedDocument(at url: URL) -> PDFDocument? {
        guard let reloaded = PDFDocument(url: url), reloaded.pageCount > 0 else { return nil }
        guard let current = document, reloaded.pageCount == current.pageCount else { return nil }
        return reloaded
    }
}
