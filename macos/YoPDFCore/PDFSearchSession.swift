import Combine
import Foundation
import PDFKit

/// Owns the temporary search state for one reader window.
///
/// PDFKit delivers asynchronous search results through document notifications.
/// A document can have only one active find operation at a time, so a newer
/// request waits for a canceled operation to finish before it starts. This
/// keeps late notifications from an older query from being mistaken for hits
/// from the current one.
@MainActor
public final class PDFSearchSession: ObservableObject {

    @Published public private(set) var query = ""
    @Published public private(set) var results: [PDFSelection] = []
    @Published public private(set) var currentResultIndex: Int?
    @Published public private(set) var isSearching = false
    /// Changes whenever visible search results are cleared or replaced.
    @Published public private(set) var resultsRevision = 0

    public private(set) var document: PDFDocument?

    private struct Request {
        let generation: Int
        let query: String
        let document: PDFDocument
        var debounceElapsed = false
    }

    @MainActor
    private final class ActiveOperation {
        let generation: Int
        let document: PDFDocument
        var observerTokens: [NSObjectProtocol] = []
        var matches: [PDFSelection] = []

        init(generation: Int, document: PDFDocument) {
            self.generation = generation
            self.document = document
        }
    }

    /// PDFKit sends notifications through NotificationCenter's main operation
    /// queue. This wrapper carries those object references into the isolated
    /// callback without exposing them to any background use.
    private struct FindNotificationPayload: @unchecked Sendable {
        let document: PDFDocument?
        let selection: PDFSelection?
    }

    private let debounceNanoseconds: UInt64
    private var generation = 0
    private var debounceTask: Task<Void, Never>?
    private var pendingRequest: Request?
    private var activeOperation: ActiveOperation?
    private var pendingNavigationOffset = 0

    /// - Parameter debounceNanoseconds: Delay before starting a query. The app
    ///   uses 200ms; tests can supply zero for faster deterministic fixtures.
    public init(debounceNanoseconds: UInt64 = 200_000_000) {
        self.debounceNanoseconds = debounceNanoseconds
    }

    public var currentSelection: PDFSelection? {
        guard let currentResultIndex,
              results.indices.contains(currentResultIndex)
        else { return nil }
        return results[currentResultIndex]
    }

    /// Rebinds the current query when the reader replaces its PDFDocument,
    /// including the identity swaps performed after Save and Save As.
    public func documentWasReplaced(with document: PDFDocument?) {
        guard self.document !== document else { return }
        search(query, in: document)
    }

    /// Starts an exact, case-insensitive search after a short typing pause.
    /// Repeating the same query for the same document preserves the current
    /// result position, which is useful when ⌘F is pressed again.
    public func search(_ rawQuery: String, in document: PDFDocument?) {
        let normalizedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedQuery == query, self.document === document {
            return
        }

        generation &+= 1
        let requestGeneration = generation
        debounceTask?.cancel()
        debounceTask = nil
        pendingRequest = nil
        pendingNavigationOffset = 0

        query = normalizedQuery
        self.document = document
        results = []
        currentResultIndex = nil
        resultsRevision &+= 1

        guard !normalizedQuery.isEmpty, let document else {
            isSearching = false
            cancelActiveOperation()
            return
        }

        isSearching = true
        pendingRequest = Request(
            generation: requestGeneration,
            query: normalizedQuery,
            document: document
        )
        cancelActiveOperation()
        schedulePendingRequest(generation: requestGeneration)
    }

    /// Clears temporary results and cancels any in-flight or debounced search.
    public func clear() {
        generation &+= 1
        debounceTask?.cancel()
        debounceTask = nil
        pendingRequest = nil
        pendingNavigationOffset = 0
        query = ""
        document = nil
        results = []
        currentResultIndex = nil
        isSearching = false
        resultsRevision &+= 1
        cancelActiveOperation()
    }

    /// Moves through hits and wraps at either end. A navigation command typed
    /// while the current query is still being collected is applied on finish.
    public func move(by offset: Int) {
        guard offset != 0 else { return }
        guard !results.isEmpty, let currentResultIndex else {
            if isSearching {
                pendingNavigationOffset += offset
            }
            return
        }

        let count = results.count
        let normalizedOffset = ((offset % count) + count) % count
        self.currentResultIndex = (currentResultIndex + normalizedOffset) % count
    }

    private func schedulePendingRequest(generation requestGeneration: Int) {
        debounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.debounceNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.generation == requestGeneration,
                  self.pendingRequest?.generation == requestGeneration
            else { return }

            self.debounceTask = nil
            self.pendingRequest?.debounceElapsed = true
            self.startPendingRequestIfPossible()
        }
    }

    private func startPendingRequestIfPossible() {
        guard activeOperation == nil,
              let request = pendingRequest,
              request.debounceElapsed,
              request.generation == generation
        else { return }

        pendingRequest = nil
        activeOperation = ActiveOperation(
            generation: request.generation,
            document: request.document
        )

        let center = NotificationCenter.default
        let operationGeneration = request.generation
        let foundToken = center.addObserver(
            forName: .PDFDocumentDidFindMatch,
            object: request.document,
            queue: .main
        ) { [weak self] notification in
            let payload = FindNotificationPayload(
                document: notification.object as? PDFDocument,
                selection: notification.userInfo?[PDFDocumentFoundSelectionKey] as? PDFSelection
            )
            MainActor.assumeIsolated {
                self?.didFindMatch(payload, generation: operationGeneration)
            }
        }
        let endedToken = center.addObserver(
            forName: .PDFDocumentDidEndFind,
            object: request.document,
            queue: .main
        ) { [weak self] notification in
            let payload = FindNotificationPayload(
                document: notification.object as? PDFDocument,
                selection: nil
            )
            MainActor.assumeIsolated {
                self?.didEndFind(payload, generation: operationGeneration)
            }
        }
        activeOperation?.observerTokens = [foundToken, endedToken]

        request.document.beginFindString(
            request.query,
            withOptions: [.caseInsensitive, .literal]
        )
    }

    private func didFindMatch(_ payload: FindNotificationPayload, generation: Int) {
        guard let operation = activeOperation,
              operation.generation == generation,
              generation == self.generation,
              operation.document === payload.document,
              let match = payload.selection
        else { return }

        operation.matches.append(match)
    }

    private func didEndFind(_ payload: FindNotificationPayload, generation: Int) {
        guard let operation = activeOperation,
              operation.generation == generation,
              operation.document === payload.document
        else { return }

        removeObservers(from: operation)
        activeOperation = nil

        if generation == self.generation,
           document === operation.document,
           !query.isEmpty {
            results = operation.matches
            currentResultIndex = results.isEmpty ? nil : 0
            if !results.isEmpty, pendingNavigationOffset != 0 {
                let count = results.count
                let offset = ((pendingNavigationOffset % count) + count) % count
                currentResultIndex = ((currentResultIndex ?? 0) + offset) % count
            }
            pendingNavigationOffset = 0
            resultsRevision &+= 1
            isSearching = false
        }

        startPendingRequestIfPossible()
    }

    private func cancelActiveOperation() {
        guard let activeOperation, activeOperation.document.isFinding else { return }
        activeOperation.document.cancelFindString()
    }

    private func removeObservers(from operation: ActiveOperation) {
        for token in operation.observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
