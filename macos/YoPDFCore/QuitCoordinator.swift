import Foundation

/// A window the quit coordinator can ask about its unsaved edits.
///
/// `WindowCloseGuard` is the production conformer; tests use a small stand-in so
/// the quit sequence can be exercised without a window server.
@MainActor
public protocol QuitConfirmingWindow: AnyObject {
    /// Whether the document still holds edits that are not on disk.
    var hasUnsavedChanges: Bool { get }
    /// Monotonic revision of those edits. See `PDFDocumentModel.editRevision`.
    var editRevision: Int { get }
    /// Presents the quit prompt for this window.
    func requestQuitConfirmation()
    /// Drops the edits now that termination is committed.
    func discardUnsavedChangesForQuit()
}

/// The decision state of one quit attempt.
///
/// AppKit quits in a sequence: `applicationShouldTerminate` asks one window,
/// returns `.terminateCancel`, and only asks the next when the previous answer
/// says to continue. A "Don't Save" in that sequence is an answer about the
/// *attempt*, not a change to the document: the window stays open and keeps its
/// dirty state until the whole sequence succeeds.
///
/// An approval is tied to the edit revision it was given for. A later edit, a
/// save, or a different document in the same window makes it stale, so the
/// window is asked again rather than silently discarding edits the user never
/// approved.
@MainActor
public final class QuitCoordinator<Window: QuitConfirmingWindow> {

    private var approvals: [ObjectIdentifier: Int] = [:]

    public init() {}

    /// The window that must answer next, or `nil` when termination may go
    /// ahead. Approvals for closed windows and for edits that changed since the
    /// answer are dropped first.
    public func nextWindowToAsk(among windows: [Window]) -> Window? {
        let current = Dictionary(
            windows.map { (ObjectIdentifier($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        approvals = approvals.filter { id, revision in
            guard let window = current[id], window.hasUnsavedChanges else { return false }
            return window.editRevision == revision
        }
        return windows.first { window in
            window.hasUnsavedChanges && approvals[ObjectIdentifier(window)] == nil
        }
    }

    /// Records "Don't Save" for this window in this attempt. The document is
    /// deliberately left untouched, including its dirty state.
    public func approveDiscard(of window: Window) {
        approvals[ObjectIdentifier(window)] = window.editRevision
    }

    /// The attempt stopped before termination. No approval survives into the
    /// next attempt, so every still-dirty window will be asked again.
    public func cancel() {
        approvals.removeAll()
    }

    /// Termination is confirmed. Now — and only now — the approved edits are
    /// dropped. The revision is read again here, so an edit made after the
    /// answer keeps the window dirty and is never discarded by a stale approval.
    public func commit(among windows: [Window]) {
        let approved = approvals
        approvals.removeAll()
        for window in windows {
            guard window.hasUnsavedChanges,
                  approved[ObjectIdentifier(window)] == window.editRevision else { continue }
            window.discardUnsavedChangesForQuit()
        }
    }
}
