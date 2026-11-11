import Foundation
import PDFKit

/// A save that never reached the file store.
public enum SaveError: Error, Equatable, Sendable {
    case noDocument
    /// PDFKit could not serialise the document. Nothing was written.
    case serializationFailed
    case sessionUnavailable
    case store(DocumentStoreError)
}

/// The result of a save attempt, in the terms the reader needs.
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

enum AutomaticSaveWorker {
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

    public var canAddHighlight: Bool {
        paneModel.canAddHighlight
    }

    @discardableResult
    public func addHighlightToSelection() -> HighlightService.Summary? {
        paneModel.addHighlightToSelection()
    }

    @discardableResult
    public func addUnderlineToSelection() -> HighlightService.Summary? {
        paneModel.addUnderlineToSelection()
    }

    // MARK: - Saving

    @discardableResult
    public func save() -> SaveOutcome {
        resourceSession.save()
    }

    func scheduleAutoSave() {
        resourceSession.scheduleAutoSave()
    }

    func restoreAutoSaveAfterFailedOpen(
        wasScheduled: Bool,
        activeWorkMatchesSchedule: Bool,
        writeWasCancelledBeforeStart: Bool?,
        completedOutcome: SaveOutcome?
    ) {
        resourceSession.restoreAutoSaveAfterFailedOpen(
            wasScheduled: wasScheduled,
            activeWorkMatchesSchedule: activeWorkMatchesSchedule,
            writeWasCancelledBeforeStart: writeWasCancelledBeforeStart,
            completedOutcome: completedOutcome
        )
    }

    public func withAutoSavePaused<T>(_ operation: () throws -> T) rethrows -> T {
        try resourceSession.withAutoSavePaused(operation)
    }

    func pauseAutoSave() {
        resourceSession.pauseAutoSave()
    }

    func resumeAutoSave() {
        resourceSession.resumeAutoSave()
    }

    @discardableResult
    func cancelPendingAutoSave(cancelInFlightWork: Bool = false) -> Bool? {
        resourceSession.cancelPendingAutoSave(cancelInFlightWork: cancelInFlightWork)
    }

    @discardableResult
    func waitForAutoSaveWork() -> SaveOutcome? {
        resourceSession.waitForAutoSaveWork()
    }

    @discardableResult
    public func saveAs(to destination: URL, overwrite: Bool = false) -> SaveOutcome {
        let outcome = resourceSession.saveAs(to: destination, overwrite: overwrite)
        if outcome == .saved {
            paneModel.clearMarkupSelection()
        }
        return outcome
    }

    public func abandonUnsavedChanges() {
        resourceSession.abandonUnsavedChanges()
        paneModel.clearMarkupSelection()
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
