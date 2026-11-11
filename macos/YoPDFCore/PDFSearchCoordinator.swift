import AppKit
import Foundation
import PDFKit

/// Coordinates and serializes PDFKit find operations against a single `PDFDocument`.
///
/// `PDFDocument` supports only one active find operation at a time. The coordinator
/// enforces FIFO execution across multiple observing panes, coalesces rapid query
/// updates from the same pane, drains cancellations before starting queued requests,
/// and ensures results are isolated to their originating pane.
@MainActor
public final class PDFSearchCoordinator {

    public struct RequestID: Hashable, Equatable, Sendable {
        public let rawValue: Int

        public init(_ rawValue: Int) {
            self.rawValue = rawValue
        }
    }

    private struct QueuedSearchRequest {
        let requestID: RequestID
        let paneID: UUID
        let query: String
        let onMatch: (PDFSelection) -> Void
        let onComplete: ([PDFSelection]) -> Void
    }

    private final class ActiveSearchRequest {
        let requestID: RequestID
        let paneID: UUID
        let query: String
        let document: PDFDocument
        var matches: [PDFSelection] = []
        var isCancelled: Bool = false
        var observerTokens: [NSObjectProtocol] = []
        let onMatch: (PDFSelection) -> Void
        let onComplete: ([PDFSelection]) -> Void

        init(
            requestID: RequestID,
            paneID: UUID,
            query: String,
            document: PDFDocument,
            onMatch: @escaping (PDFSelection) -> Void,
            onComplete: @escaping ([PDFSelection]) -> Void
        ) {
            self.requestID = requestID
            self.paneID = paneID
            self.query = query
            self.document = document
            self.onMatch = onMatch
            self.onComplete = onComplete
        }
    }

    private struct FindNotificationPayload: @unchecked Sendable {
        let document: PDFDocument?
        let selection: PDFSelection?
    }

    private weak var document: PDFDocument?
    private var activeRequest: ActiveSearchRequest?
    private var queuedRequests: [QueuedSearchRequest] = []
    private var isDrainingCancellation: Bool = false
    private var nextRequestNumber: Int = 1

    public init(document: PDFDocument? = nil) {
        self.document = document
    }

    public var isFinding: Bool {
        activeRequest != nil || isDrainingCancellation || !queuedRequests.isEmpty
    }

    public var activePaneID: UUID? {
        activeRequest?.paneID
    }

    public var queuedCount: Int {
        queuedRequests.count
    }

    /// Rebinds the coordinator to a replacement document, clearing any in-flight
    /// or queued search operations.
    public func bindDocument(_ newDocument: PDFDocument?) {
        guard document !== newDocument else { return }
        cancelAll()
        self.document = newDocument
    }

    /// Submits a search request from a specific pane.
    ///
    /// If an active operation is already running for a different pane, this request
    /// is queued. If an active operation is running for the same pane, it is cancelled
    /// and the new query is scheduled once the cancellation finishes draining.
    /// If multiple requests from the same pane are queued, they are coalesced.
    @discardableResult
    public func requestSearch(
        paneID: UUID,
        query rawQuery: String,
        onMatch: @escaping (PDFSelection) -> Void = { _ in },
        onComplete: @escaping ([PDFSelection]) -> Void
    ) -> RequestID? {
        let normalized = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, let document else {
            cancelSearch(for: paneID)
            onComplete([])
            return nil
        }

        let requestID = RequestID(nextRequestNumber)
        nextRequestNumber &+= 1

        let queued = QueuedSearchRequest(
            requestID: requestID,
            paneID: paneID,
            query: normalized,
            onMatch: onMatch,
            onComplete: onComplete
        )

        if let active = activeRequest, active.paneID == paneID {
            // Self-cancellation: The requesting pane changed its query while its
            // previous query was actively running in PDFKit.
            active.isCancelled = true
            enqueueOrCoalesce(queued)
            if active.document.isFinding {
                isDrainingCancellation = true
                active.document.cancelFindString()
            } else {
                removeObservers(for: active)
                activeRequest = nil
                isDrainingCancellation = false
                startNextIfPossible()
            }
            return requestID
        }

        if activeRequest != nil || isDrainingCancellation {
            // Another pane is active or an old cancel is still draining.
            enqueueOrCoalesce(queued)
            return requestID
        }

        start(request: queued, in: document)
        return requestID
    }

    /// Cancels active and queued searches for a specific pane without interrupting
    /// other panes' active or queued operations.
    public func cancelSearch(for paneID: UUID) {
        queuedRequests.removeAll { $0.paneID == paneID }

        if let active = activeRequest, active.paneID == paneID {
            active.isCancelled = true
            if active.document.isFinding {
                isDrainingCancellation = true
                active.document.cancelFindString()
            } else {
                removeObservers(for: active)
                activeRequest = nil
                isDrainingCancellation = false
                startNextIfPossible()
            }
        }
    }

    /// Immediately terminates all searches and clears the queue (e.g. on close or document swap).
    public func cancelAll() {
        queuedRequests.removeAll()

        if let active = activeRequest {
            active.isCancelled = true
            removeObservers(for: active)
            if active.document.isFinding {
                active.document.cancelFindString()
            }
            activeRequest = nil
        }
        isDrainingCancellation = false
    }

    private func enqueueOrCoalesce(_ request: QueuedSearchRequest) {
        if let existingIndex = queuedRequests.firstIndex(where: { $0.paneID == request.paneID }) {
            // Coalesce: keep the latest query and callback for this pane
            queuedRequests[existingIndex] = request
        } else {
            queuedRequests.append(request)
        }
    }

    private func start(request: QueuedSearchRequest, in document: PDFDocument) {
        let active = ActiveSearchRequest(
            requestID: request.requestID,
            paneID: request.paneID,
            query: request.query,
            document: document,
            onMatch: request.onMatch,
            onComplete: request.onComplete
        )
        self.activeRequest = active

        let operationID = request.requestID
        let center = NotificationCenter.default

        let foundToken = center.addObserver(
            forName: .PDFDocumentDidFindMatch,
            object: document,
            queue: .main
        ) { [weak self] notification in
            let payload = FindNotificationPayload(
                document: notification.object as? PDFDocument,
                selection: notification.userInfo?[PDFDocumentFoundSelectionKey] as? PDFSelection
            )
            MainActor.assumeIsolated {
                self?.didFindMatch(payload, requestID: operationID)
            }
        }

        let endedToken = center.addObserver(
            forName: .PDFDocumentDidEndFind,
            object: document,
            queue: .main
        ) { [weak self] notification in
            let payload = FindNotificationPayload(
                document: notification.object as? PDFDocument,
                selection: nil
            )
            MainActor.assumeIsolated {
                self?.didEndFind(payload, requestID: operationID)
            }
        }

        active.observerTokens = [foundToken, endedToken]
        document.beginFindString(request.query, withOptions: [.caseInsensitive, .literal])
    }

    private func didFindMatch(_ payload: FindNotificationPayload, requestID: RequestID) {
        guard let active = activeRequest,
              active.requestID == requestID,
              !active.isCancelled,
              active.document === payload.document,
              let match = payload.selection
        else { return }

        active.matches.append(match)
        active.onMatch(match)
    }

    private func didEndFind(_ payload: FindNotificationPayload, requestID: RequestID) {
        guard let active = activeRequest,
              active.requestID == requestID,
              active.document === payload.document
        else { return }

        removeObservers(for: active)
        let completed = active
        self.activeRequest = nil
        self.isDrainingCancellation = false

        if !completed.isCancelled {
            completed.onComplete(completed.matches)
        }

        startNextIfPossible()
    }

    private func startNextIfPossible() {
        guard activeRequest == nil,
              !isDrainingCancellation,
              !queuedRequests.isEmpty,
              let document = self.document
        else { return }

        Task { @MainActor [weak self] in
            guard let self,
                  self.activeRequest == nil,
                  !self.isDrainingCancellation,
                  !self.queuedRequests.isEmpty,
                  let document = self.document
            else { return }

            let next = self.queuedRequests.removeFirst()
            self.start(request: next, in: document)
        }
    }

    private func removeObservers(for active: ActiveSearchRequest) {
        for token in active.observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        active.observerTokens.removeAll()
    }
}
