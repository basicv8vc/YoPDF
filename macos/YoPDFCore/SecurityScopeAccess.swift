import Foundation

/// Abstraction over security-scoped resource access so the document model's
/// acquire/release lifecycle can be tested without a sandboxed process.
public protocol SecurityScopeAccessing: Sendable {
    /// Returns `true` when a scope was actually acquired and must be released.
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

/// The real implementation. Outside a sandbox `startAccessing` returns `false`,
/// which is a valid outcome: there is no scope to release.
public struct SystemSecurityScopeAccess: SecurityScopeAccessing {
    public init() {}

    public func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    public func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

/// One acquired scope. Releases exactly once, including when the owning model is
/// deallocated without an explicit `close()`.
final class SecurityScopeLease {
    let url: URL

    private let access: any SecurityScopeAccessing
    private let didStart: Bool
    private var isReleased = false

    init(url: URL, access: any SecurityScopeAccessing) {
        self.url = url
        self.access = access
        self.didStart = access.startAccessing(url)
    }

    /// Idempotent: a failed open releases the candidate lease, and the lease's
    /// own deinit must not release it a second time.
    func release() {
        guard didStart, !isReleased else { return }
        isReleased = true
        access.stopAccessing(url)
    }

    deinit {
        release()
    }
}
