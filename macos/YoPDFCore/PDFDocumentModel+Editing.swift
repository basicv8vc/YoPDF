import Foundation
import PDFKit

/// A save that never reached the file store.
///
/// Kept apart from `DocumentStoreError` because these happen before the store is
/// involved at all: there is no file-level outcome to report, and no bytes were
/// staged.
public enum SaveError: Error, Equatable, Sendable {
    case noDocument
    /// PDFKit could not serialise the document. Nothing was written.
    case serializationFailed
    case sessionUnavailable
    case store(DocumentStoreError)
}

/// The result of a save attempt, in the terms the reader needs.
///
/// The distinction that matters is not "success / failure" but **whether the
/// bytes reached the file**: a save that wrote the file and then failed to
/// re-sync the in-memory document is a different situation from a save that
/// wrote nothing, and telling the user "your work was not saved" in the first
/// case would be a lie that invites a destructive retry.
public enum SaveOutcome: Equatable, Sendable {
    /// The file was written and the in-memory document now matches it.
    case saved
    /// The file was written, but the app could not confirm or re-sync it.
    /// `editsOnDisk` says whether the edits may be treated as stored.
    case savedUnverified(reason: String, editsOnDisk: Bool)
    /// Nothing was written: the file changed underneath, and the edits are
    /// still only in memory.
    case conflict(DocumentStoreError)
    /// The replacement ended in a state that could not be classified. Every
    /// surviving copy is listed; nothing was deleted.
    case uncertain(reason: String, recovery: [URL])
    /// Nothing was written.
    case failed(SaveError)

    /// Whether the current edits are known to be on disk.
    public var editsAreOnDisk: Bool {
        switch self {
        case .saved:
            return true
        case let .savedUnverified(_, editsOnDisk):
            return editsOnDisk
        case .conflict, .uncertain, .failed:
            return false
        }
    }
}

/// The visible state of automatic annotation saving.
public enum AutoSaveStatus: Equatable {
    case idle
    /// An annotation changed and the debounce interval has not elapsed yet.
    case pending
    case saving
    case saved
    /// The automatic save did not finish as a verified success.
    case failed(SaveOutcome)
}

/// A synchronous wait point for lifecycle and manual-save operations that must
/// not race an automatic write already running on a worker thread.
final class AutoSaveWorkCompletion: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var writeHasStarted = false
    private var wasCancelledBeforeWrite = false
    private var completedOutcome: SaveOutcome?

    var didStartWrite: Bool { lock.withLock { writeHasStarted } }
    var outcome: SaveOutcome? { lock.withLock { completedOutcome } }

    /// Resolves the Save As/close race at a single boundary: if cancellation
    /// wins before this point, the worker will not touch the original file. If
    /// the write already started, callers wait for its coordinated transaction.
    func beginWriteUnlessCancelled() -> Bool {
        lock.withLock {
            guard !wasCancelledBeforeWrite else { return false }
            writeHasStarted = true
            return true
        }
    }

    @discardableResult
    func cancelBeforeWrite() -> Bool {
        lock.withLock {
            guard !writeHasStarted else { return false }
            wasCancelledBeforeWrite = true
            return true
        }
    }

    func complete(with outcome: SaveOutcome) {
        lock.withLock { completedOutcome = outcome }
        semaphore.signal()
    }
    func wait() { semaphore.wait() }
}

private enum AutomaticSaveWorker {
    static func save(_ data: Data, to session: DocumentSession, pageCount: Int) -> SaveOutcome {
        do {
            try session.save(data)
        } catch let error as DocumentStoreError {
            return resolve(error, session: session, pageCount: pageCount)
        } catch {
            return .failed(.store(.stagingFailed(error.localizedDescription)))
        }
        return verifySavedPDF(at: session.url, pageCount: pageCount)
    }

    private static func resolve(
        _ error: DocumentStoreError,
        session: DocumentSession,
        pageCount: Int
    ) -> SaveOutcome {
        switch error {
        case let .committedButUnverified(_, reason):
            do {
                _ = try session.refresh()
                return verifySavedPDF(at: session.url, pageCount: pageCount)
            } catch {
                let detail = (error as? DocumentStoreError)?.localizedDescription
                    ?? error.localizedDescription
                return .savedUnverified(reason: "\(reason) \(detail)", editsOnDisk: false)
            }
        case let .externalModificationDetected(change):
            return .conflict(.externalModificationDetected(change))
        case let .replacementStateUncertain(recovery):
            return .uncertain(
                reason: DocumentStoreError.replacementStateUncertain(recovery).localizedDescription,
                recovery: recovery.recoverableURLs
            )
        default:
            return .failed(.store(error))
        }
    }

    private static func verifySavedPDF(at url: URL, pageCount: Int) -> SaveOutcome {
        guard let reopened = PDFDocument(url: url),
              reopened.pageCount > 0,
              reopened.pageCount == pageCount
        else {
            return .savedUnverified(
                reason: "The file was written, but it could not be reopened.",
                editsOnDisk: true
            )
        }
        return .saved
    }
}

extension PDFDocumentModel {

    // MARK: - Highlight

    /// Whether the Highlight command would produce a real annotation.
    ///
    /// Drives the button and the menu item, so both agree with what
    /// `HighlightService` will accept.
    public var canAddHighlight: Bool {
        canAddMarkup(.highlight)
    }

    /// Highlights the current selection, if it holds text.
    ///
    /// Returns what was added, or `nil` when there was nothing to highlight —
    /// in which case the document is left exactly as it was.
    @discardableResult
    public func addHighlightToSelection() -> HighlightService.Summary? {
        addMarkup(.highlight)
    }

    /// Underlines the current selection, using the Underline default colour.
    @discardableResult
    public func addUnderlineToSelection() -> HighlightService.Summary? {
        addMarkup(.underline)
    }

    // MARK: - Saving

    /// Writes the in-memory document back through its session.
    ///
    /// The document is serialised with PDFKit and handed to `DocumentSession`,
    /// which owns the version check, the staging file and the coordinated
    /// replacement. Nothing here writes to the original path directly: doing so
    /// would bypass the external-change check that makes a save safe.
    ///
    /// After a successful manual write the document is re-opened from the file.
    /// That is not cosmetic: the replacement gives the file a new inode, so the
    /// `PDFDocument` that was memory-mapping the old one no longer describes the
    /// file the session now owns. Automatic saves verify a reopened copy but
    /// keep the live document so annotation undo history remains usable.
    @discardableResult
    public func save() -> SaveOutcome {
        // A manual save supersedes the debounce. If it fails, do not run a
        // second automatic attempt against the same document a moment later.
        cancelPendingAutoSave(cancelInFlightWork: true)
        waitForAutoSaveWork()
        return save(preservingUndoHistory: false)
    }

    private func save(preservingUndoHistory: Bool) -> SaveOutcome {
        guard let document, let session = documentSession else { return .failed(.noDocument) }
        guard hasUnsavedChanges else { return .saved }
        guard let data = NoteService.dataRepresentationPreservingShuaGroups(in: document) else {
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

    /// Reschedules a save after each document edit. The short quiet period
    /// groups related UI changes (for example, dragging a note marker or
    /// choosing a custom colour) into one safe file replacement.
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

    /// Restores automatic saving after a failed replacement. A matching writer
    /// that finished while the candidate was loading is applied by its result;
    /// otherwise the still-dirty current document gets a fresh debounce.
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

    /// Runs a synchronous modal workflow while pausing the pending debounce.
    /// An in-flight write is allowed to finish; a pending write resumes after
    /// the workflow only if the document is still dirty.
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

        // The lock shared with beginWriteUnlessCancelled() decides which side
        // of the modal-panel boundary this save belongs to.
        let cancellationWon = autoSaveWorkCompletion?.cancelBeforeWrite()
        let writeAlreadyStarted = cancellationWon == false
        // A write that already crossed this boundary owns its transaction and
        // may finish. Otherwise invalidate the scheduled attempt and close the
        // same cancellation gate the worker checks after PDF serialization.
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

        // A later edit can expire its debounce while an earlier snapshot is
        // still being written. Wait for that write before capturing the newer
        // snapshot so an older version can never replace a newer one on disk.
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
            // Save As, manual Save, close or discard may cancel a worker while
            // PDFKit is serializing. Atomically claim the file-write phase so
            // cancellation cannot slip between the check and DocumentSession.
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

    /// Cancels a pending automatic save when the user saves, discards, closes,
    /// or successfully replaces the open document.
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

    /// Waits only for an already-started snapshot write. Debounce cancellation
    /// is immediate; this prevents a later manual save, Save As or close from
    /// racing the file session while its worker is active.
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

    /// Writes the document to another file and continues editing there.
    ///
    /// The escape hatch for a read-only file, a hard link, or a conflict the
    /// user does not want to resolve in place.
    @discardableResult
    public func saveAs(to destination: URL, overwrite: Bool = false) -> SaveOutcome {
        // A Save As selected during the debounce captures the edits into the
        // new file and leaves the original untouched. A worker that has entered
        // DocumentSession.save is allowed to finish before Save As.
        cancelPendingAutoSave(cancelInFlightWork: true)
        waitForAutoSaveWork()
        guard let document, let session = documentSession else { return .failed(.noDocument) }
        guard let data = NoteService.dataRepresentationPreservingShuaGroups(in: document) else {
            return .failed(.serializationFailed)
        }

        do {
            let newSession = try session.saveAs(data, to: destination, overwrite: overwrite)
            // Read the new file before the old session is closed: closing it
            // releases the access the still-displayed document was opened
            // under, and there is no reason to make the reader depend on how
            // long PDFKit keeps its own descriptor open.
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
            swapDocument(reloaded, at: readingPosition)
            return .saved
        } catch let error as DocumentStoreError {
            return resolveSaveAsFailure(error)
        } catch {
            return .failed(.store(.stagingFailed(error.localizedDescription)))
        }
    }

    /// Forgets the edits without writing anything.
    ///
    /// Only correct when the document is about to be closed or replaced: the
    /// in-memory annotations are still there, so the model must not keep
    /// claiming they are unsaved after the user chose to discard them.
    public func abandonUnsavedChanges() {
        cancelPendingAutoSave(cancelInFlightWork: true)
        waitForAutoSaveWork()
        markSaved()
    }

    // MARK: - Outcomes

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
            // The bytes are on disk; the session just could not read the new
            // version back. `refresh()` is the only operation that can turn
            // "probably written" into a known state, so try it before
            // reporting anything to the user.
            do {
                _ = try session.refresh()
                return finishWrite(preservingUndoHistory: preservingUndoHistory)
            } catch {
                let detail = (error as? DocumentStoreError)?.localizedDescription
                    ?? error.localizedDescription
                // Undecided: keep the edits marked unsaved so nothing treats
                // them as safely stored.
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

    /// Save As, in the same three-way split as a save: committed, not
    /// committed, or undecided.
    ///
    /// The distinction matters more here than for a save in place, because the
    /// original file is untouched either way — what is at stake is whether the
    /// *copy* exists and whether this window still owns unsaved edits.
    private func resolveSaveAsFailure(_ error: DocumentStoreError) -> SaveOutcome {
        switch error {
        case let .committedButUnverified(url, reason):
            // The copy was written; only taking ownership of it failed. Opening
            // a session here is what keeps the window pointed at a real file
            // instead of leaving it on the original while claiming nothing
            // happened.
            if let reopened = try? store.open(url) {
                adoptSession(reopened)
                adoptFileLocation(url)
                return finishWrite()
            }
            // Still committed, and still not adoptable. Reporting this as a
            // plain failure would invite the user to save again on top of a
            // copy that already exists, so it is reported as what it is: the
            // bytes are on disk, the window could not switch to them, and the
            // edits stay marked unsaved because this window is still showing
            // the original file.
            return .savedUnverified(
                reason: "“\(url.lastPathComponent)” was written, but it could not be opened, "
                    + "so this window is still showing the original file. \(reason)",
                editsOnDisk: true
            )
        case let .externalModificationDetected(change):
            // The destination changed between the panel and the commit. The
            // copy was not written; the edits are still only in memory.
            return .conflict(.externalModificationDetected(change))
        case let .replacementStateUncertain(recovery):
            // The destination may hold the copy, the original of the
            // destination, or neither. Nothing was deleted.
            return uncertainOutcome(recovery)
        default:
            return .failed(.store(error))
        }
    }

    /// A replacement that ended in a state the store could not classify.
    ///
    /// Every surviving file is listed and the edits stay unsaved: the outcome is
    /// "unknown", which is not the same as "failed" and must not be presented as
    /// one.
    private func uncertainOutcome(_ recovery: ReplacementRecovery) -> SaveOutcome {
        .uncertain(
            reason: DocumentStoreError.replacementStateUncertain(recovery).localizedDescription,
            recovery: recovery.recoverableURLs
        )
    }

    /// Re-opens the file the session now owns and swaps it in, keeping the
    /// reading position.
    ///
    /// Returns a reason when the swap could not happen. That is **not** a failed
    /// save: the bytes are already committed, and the caller reports it as
    /// "saved, but the view could not be re-synced" instead.
    private func resyncDocumentAfterWrite() -> String? {
        guard let url = fileURL else { return "The document has no file location." }
        guard let reloaded = reloadedDocument(at: url) else {
            return "The file was written, but it could not be reopened."
        }
        swapDocument(reloaded, at: readingPosition)
        return nil
    }

    /// Re-opens the saved file to verify it is readable without swapping the
    /// live document. Automatic-save undo entries retain references to its
    /// annotation objects, so replacing it here would make ⌘Z edit an offscreen
    /// document.
    private func verifyDocumentAfterWrite() -> String? {
        guard let url = fileURL else { return "The document has no file location." }
        guard reloadedDocument(at: url) != nil else {
            return "The file was written, but it could not be reopened."
        }
        return nil
    }

    /// Re-opens `url` and checks that it still describes the same document.
    ///
    /// Refusing a reload that lost pages is deliberate: the file is written
    /// either way, but the reader should keep showing something coherent until
    /// the user reopens it.
    private func reloadedDocument(at url: URL) -> PDFDocument? {
        guard let reloaded = PDFDocument(url: url), reloaded.pageCount > 0 else { return nil }
        guard let current = document, reloaded.pageCount == current.pageCount else { return nil }
        return reloaded
    }
}

extension SaveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noDocument:
            return "There is no document to save."
        case .serializationFailed:
            return "The document could not be prepared for saving. The file was not changed."
        case .sessionUnavailable:
            return "The document is no longer open."
        case let .store(error):
            return error.errorDescription
        }
    }
}
