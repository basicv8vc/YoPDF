import Foundation
@testable import YoPDFCore

/// Records security-scope acquisitions and releases so tests can assert the
/// lifecycle, not merely that a `PDFDocument` object survived.
final class SecurityScopeSpy: SecurityScopeAccessing, @unchecked Sendable {

    enum Event: Equatable {
        case start(URL)
        case stop(URL)
    }

    private let lock = NSLock()
    private var storage: [Event] = []

    /// Mirrors the real system: outside a sandbox `startAccessing` returns false.
    var startResult = true

    var events: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var starts: [URL] {
        events.compactMap { if case let .start(url) = $0 { return url } else { return nil } }
    }

    var stops: [URL] {
        events.compactMap { if case let .stop(url) = $0 { return url } else { return nil } }
    }

    func startAccessing(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        storage.append(.start(url))
        return startResult
    }

    func stopAccessing(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(.stop(url))
    }
}
