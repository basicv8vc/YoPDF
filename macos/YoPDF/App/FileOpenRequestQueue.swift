import Combine
import Foundation

/// Keeps the app's Finder-open policy to one request at a time.
///
/// The slot stays occupied after the reader takes the URL, until it finishes
/// opening it or the user resolves/cancels the unsaved-work prompt. This avoids
/// both stranded URLs and replacing the action underneath a visible prompt.
@MainActor
final class FileOpenRequestQueue: ObservableObject {

    @Published private(set) var revision = 0
    private var pendingURL: URL?
    private var requestIsActive = false
    private var readerWindowOpener: (@MainActor () -> Void)?
    private(set) var hasHadReaderWindow = false

    /// Accepts one request. Further events fail until `finishRequest()` is
    /// called, including while the first request is being confirmed.
    @discardableResult
    func enqueue(_ url: URL) -> Bool {
        guard !requestIsActive else { return false }
        pendingURL = url
        requestIsActive = true
        revision &+= 1
        return true
    }

    func takeNext() -> URL? {
        guard let url = pendingURL else { return nil }
        pendingURL = nil
        revision &+= 1
        return url
    }

    func finishRequest() {
        guard requestIsActive else { return }
        pendingURL = nil
        requestIsActive = false
        revision &+= 1
    }

    func registerReaderWindowOpener(_ opener: @escaping @MainActor () -> Void) {
        readerWindowOpener = opener
    }

    func readerWindowDidBecomeAvailable() {
        hasHadReaderWindow = true
    }

    func openReaderWindowIfAvailable() {
        readerWindowOpener?()
    }
}
