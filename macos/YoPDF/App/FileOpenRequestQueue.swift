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
    /// The URL currently being handled by a reader. Keep it until the reader
    /// finishes so a window that closes mid-request can hand it back.
    private var inFlightURL: URL?
    private var requestIsActive = false
    private var readerWindowOpener: (@MainActor () -> Void)?
    private(set) var hasHadReaderWindow = false

    /// A Finder event need not make a reader key. Ignore non-reader windows
    /// (such as panels), then fall back to the frontmost available reader.
    static func preferredReader<ID: Hashable>(key: ID?, main: ID?, orderedReaders: [ID]) -> ID? {
        if let key, orderedReaders.contains(key) { return key }
        if let main, orderedReaders.contains(main) { return main }
        return orderedReaders.first
    }

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
        guard inFlightURL == nil, let url = pendingURL else { return nil }
        pendingURL = nil
        inFlightURL = url
        revision &+= 1
        return url
    }

    /// Re-queues the request when its reader closes before finishing it. The
    /// revision also wakes any other reader that can take over the request.
    @discardableResult
    func readerWindowDidClose() -> Bool {
        guard requestIsActive else { return false }
        if let inFlightURL {
            pendingURL = inFlightURL
            self.inFlightURL = nil
        }
        revision &+= 1
        return true
    }

    func finishRequest() {
        guard requestIsActive else { return }
        pendingURL = nil
        inFlightURL = nil
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

    /// Debug UI tests use this trace to confirm how LaunchServices routes each
    /// file-open action. Release builds compile out both the argument and I/O.
    func recordOpenCallback(_ source: String, urls: [URL]) {
        #if DEBUG
        guard let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--yopdf-open-trace=")
        }) else { return }
        let path = String(argument.dropFirst("--yopdf-open-trace=".count))
        guard !path.isEmpty else { return }

        do {
            let traceURL = URL(fileURLWithPath: path)
            let entry: [String: Any] = ["source": source, "paths": urls.map(\.path)]
            var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            data.append(0x0A)
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: Data())
            }
            let handle = try FileHandle(forWritingTo: traceURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            NSLog("YoPDF test open trace failed: %@", error.localizedDescription)
        }
        #endif
    }
}
