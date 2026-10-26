import Combine
import Foundation

/// Keeps the app's Finder-open policy to one request at a time.
///
/// The slot stays occupied after the reader takes the URL until it opens the
/// file itself or hands it to a dedicated reader window. This avoids stranded
/// URLs and duplicate delivery while the new scene is being created.
@MainActor
final class FileOpenRequestQueue: ObservableObject {

    struct ReaderWindowRequest {
        let url: URL
        let relinkingRecentDocumentID: UUID?
    }

    struct Request: Equatable, Identifiable {
        let id: UUID
        let url: URL
        /// `nil` while the URL is waiting for a reader to take it.
        let readerID: UUID?
    }

    @Published private(set) var revision = 0
    private var pendingRequest: Request?
    /// Keep the current owner and request identity until it finishes. If that
    /// reader closes, the same request can be reassigned without letting a
    /// different reader's close or a stale completion mutate it.
    private var inFlightRequest: Request?
    private var readerWindowOpener: (@MainActor () -> Void)?
    /// New WindowGroup scenes are not available for Finder events until their
    /// one-shot scene request has been consumed.
    private var readerRequestAvailability: [UUID: Bool] = [:]
    /// WindowGroup values use UUIDs so the actual file URL stays in-process.
    /// This preserves security-scoped URL state across scene creation.
    private var readerWindowRequests: [UUID: ReaderWindowRequest] = [:]
    private(set) var hasHadReaderWindow = false

    /// A Finder event need not make a reader key. Ignore non-reader windows
    /// (such as panels), then fall back to the frontmost available reader.
    static func preferredReader<ID: Hashable>(key: ID?, main: ID?, orderedReaders: [ID]) -> ID? {
        if let key, orderedReaders.contains(key) { return key }
        if let main, orderedReaders.contains(main) { return main }
        return orderedReaders.first
    }

    /// Accepts one request. Further events fail until its owner finishes it,
    /// including while the first request is being confirmed.
    @discardableResult
    func enqueue(_ url: URL) -> Bool {
        guard pendingRequest == nil, inFlightRequest == nil else { return false }
        pendingRequest = Request(id: UUID(), url: url, readerID: nil)
        revision &+= 1
        return true
    }

    func takeNext(readerID: UUID) -> Request? {
        guard readerRequestAvailability[readerID] != false,
              inFlightRequest == nil,
              let pendingRequest
        else { return nil }
        let request = Request(id: pendingRequest.id, url: pendingRequest.url, readerID: readerID)
        self.pendingRequest = nil
        inFlightRequest = request
        revision &+= 1
        return request
    }

    /// Re-queues an in-flight request only when its owner closes. A reader
    /// closing while a request is still unclaimed also wakes other readers so
    /// one can take it, or opens a replacement if none remain.
    @discardableResult
    func readerWindowDidClose(readerID: UUID) -> Bool {
        readerRequestAvailability.removeValue(forKey: readerID)
        if let inFlightRequest {
            guard inFlightRequest.readerID == readerID else { return false }
            pendingRequest = Request(
                id: inFlightRequest.id,
                url: inFlightRequest.url,
                readerID: nil
            )
            self.inFlightRequest = nil
        } else if pendingRequest == nil {
            return false
        }
        revision &+= 1
        return true
    }

    /// A stale reader cannot finish a request after it has been handed to
    /// another window.
    @discardableResult
    func finishRequest(requestID: UUID, readerID: UUID) -> Bool {
        guard inFlightRequest?.id == requestID,
              inFlightRequest?.readerID == readerID
        else { return false }
        inFlightRequest = nil
        revision &+= 1
        return true
    }

    func registerReaderWindowOpener(_ opener: @escaping @MainActor () -> Void) {
        readerWindowOpener = opener
    }

    func readerWindowDidBecomeAvailable() {
        hasHadReaderWindow = true
    }

    func setReaderCanReceiveFinderRequests(readerID: UUID, canReceive: Bool) {
        guard readerRequestAvailability[readerID] != canReceive else { return }
        readerRequestAvailability[readerID] = canReceive
        revision &+= 1
    }

    func readerCanReceiveFinderRequests(readerID: UUID) -> Bool {
        readerRequestAvailability[readerID] ?? true
    }

    func openReaderWindowIfAvailable() {
        readerWindowOpener?()
    }

    func enqueueReaderWindowRequest(
        url: URL,
        relinkingRecentDocumentID: UUID? = nil
    ) -> UUID {
        let id = UUID()
        readerWindowRequests[id] = ReaderWindowRequest(
            url: url,
            relinkingRecentDocumentID: relinkingRecentDocumentID
        )
        return id
    }

    func takeReaderWindowRequest(id: UUID) -> ReaderWindowRequest? {
        readerWindowRequests.removeValue(forKey: id)
    }

    func discardReaderWindowRequest(id: UUID) {
        _ = readerWindowRequests.removeValue(forKey: id)
    }

}
