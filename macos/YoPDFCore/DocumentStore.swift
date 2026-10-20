import Foundation

/// Opens local files for byte-level reading and safe writing.
///
/// It knows nothing about PDF pages, annotations or rendering: it deals in
/// file identity, versions and bytes. That keeps the save path testable
/// without a window, and keeps PDF semantics in the layers that own them.
///
/// The store itself is stateless. The thing that owns a file is a
/// `DocumentSession`, created by `open(_:)`.
public final class DocumentStore: Sendable {
    private let access: any SecurityScopeAccessing
    private let io: any DocumentStoreIO

    public init(
        access: any SecurityScopeAccessing = SystemSecurityScopeAccess(),
        io: any DocumentStoreIO = SystemDocumentStoreIO()
    ) {
        self.access = access
        self.io = io
    }

    /// Opens a file session and records its initial version.
    ///
    /// The security scope is acquired **before** the file is touched, because
    /// in a sandbox an existence check on an unopened security-scoped URL can
    /// fail even when the file is there. A failed open releases the candidate
    /// scope and leaves any other session untouched.
    public func open(_ url: URL) throws -> DocumentSession {
        guard url.isFileURL else { throw DocumentStoreError.notAFileURL }

        let lease = SecurityScopeLease(url: url, access: access)
        do {
            let status = try io.status(of: url)
            guard status.exists else { throw DocumentStoreError.fileMissing(url) }
            guard status.isRegularFile else {
                throw DocumentStoreError.unsupportedFileSituation(.notARegularFile, url)
            }
            if status.isCloudPlaceholder {
                throw DocumentStoreError.unsupportedFileSituation(.cloudPlaceholderNotDownloaded, url)
            }
            // A symlink is allowed here: reading through it is safe. `save`
            // refuses it, because replacing the path would replace the link.
            let version = try io.version(of: url)
            return DocumentSession(
                url: url,
                version: version,
                isWritableAtOpen: status.isWritable,
                lease: lease,
                io: io,
                access: access
            )
        } catch {
            lease.release()
            throw error
        }
    }
}

/// One open file, and the only owner of its security scope.
///
/// Everything that touches the file goes through the session, so there is a
/// single place that decides when access starts and when it ends. Closing is
/// idempotent; dropping the last reference releases the scope as well.
public final class DocumentSession: @unchecked Sendable {

    private let stateLock = NSLock()
    /// Serialises saves. Two saves of the same session must not interleave:
    /// the second one's baseline check would be meaningless.
    private let saveLock = NSLock()

    private let lease: SecurityScopeLease
    private let io: any DocumentStoreIO
    private let access: any SecurityScopeAccessing

    private var currentURL: URL
    private var currentVersion: DocumentVersion
    private var closed = false

    /// Whether the file was writable when it was opened. Diagnostic only;
    /// `save` always re-checks, because permissions can change while a
    /// document is open.
    let isWritableAtOpen: Bool

    init(
        url: URL,
        version: DocumentVersion,
        isWritableAtOpen: Bool,
        lease: SecurityScopeLease,
        io: any DocumentStoreIO,
        access: any SecurityScopeAccessing
    ) {
        self.currentURL = url
        self.currentVersion = version
        self.isWritableAtOpen = isWritableAtOpen
        self.lease = lease
        self.io = io
        self.access = access
    }

    deinit {
        // A session must not be deallocated while a save is running; callers
        // hold it for the duration of the call. Releasing here only balances
        // an open that was never explicitly closed.
        lease.release()
    }

    // MARK: - State

    public var url: URL {
        stateLock.withLock { currentURL }
    }

    /// The version this session last observed on disk.
    public var version: DocumentVersion {
        stateLock.withLock { currentVersion }
    }

    public var isClosed: Bool {
        stateLock.withLock { closed }
    }

    // MARK: - Reading

    public func read() throws -> Data {
        try ensureOpen()
        do {
            return try io.readContents(of: url)
        } catch let error as DocumentStoreError {
            throw error
        } catch {
            throw DocumentStoreError.notReadable(url, error.localizedDescription)
        }
    }

    /// Compares the file on disk with the version this session opened.
    ///
    /// Throws only when the file cannot be inspected at all (permission,
    /// unreadable). A file that is simply gone returns `.missing` rather than
    /// throwing, because that is a normal answer to "has it changed?".
    public func checkExternalChange() throws -> ExternalChange {
        try ensureOpen()
        let status = try io.status(of: url)
        guard status.exists else { return .missing }
        let onDisk = try io.version(of: url)
        return Self.classify(expected: version, current: onDisk)
    }

    // MARK: - Writing

    /// Writes `contents` back to the file this session was opened with.
    ///
    /// The original is never modified until the replacement step, and that
    /// step only runs when the file still matches the version this session
    /// opened. On any failure the original keeps its exact bytes.
    @discardableResult
    public func save(_ contents: Data) throws -> DocumentVersion {
        try ensureOpen()
        saveLock.lock()
        defer { saveLock.unlock() }
        try ensureOpen()

        let target = url
        try Self.validateSaveTarget(try io.status(of: target), url: target)

        let expected = version
        let staging = try io.createStagingFile(nextTo: target, contents: contents)

        var committed = false
        defer {
            // The staging file is consumed by a successful replacement; on
            // every other path it is removed so a failure leaves no debris.
            if !committed {
                try? io.removeItemIfExists(at: staging)
            }
        }

        let finalURL = try io.withCoordinatedWrite(at: target) { coordinatedURL in
            // Everything below runs inside the write intent, immediately
            // before the bytes are swapped. A process that ignores file
            // coordination can still have written between the check above and
            // this point, which is exactly why the check is repeated here.
            let liveStatus = try io.status(of: coordinatedURL)
            guard liveStatus.exists else {
                throw DocumentStoreError.fileMissing(coordinatedURL)
            }
            try Self.validateSaveTarget(liveStatus, url: coordinatedURL)

            let onDisk = try io.version(of: coordinatedURL)
            let change = Self.classify(expected: expected, current: onDisk)
            guard case .unchanged = change else {
                throw DocumentStoreError.externalModificationDetected(change)
            }

            return try io.replaceItem(at: coordinatedURL, with: staging)
        }

        committed = true
        // The replacement changed the inode, so the session has to adopt the
        // new identity before it can be used for another save.
        let updated = try io.version(of: finalURL)
        stateLock.withLock {
            currentURL = finalURL
            currentVersion = updated
        }
        return updated
    }

    /// Writes `contents` to `destination` and returns a **new** session for it.
    ///
    /// The receiver is left untouched: the caller decides when to close the
    /// old session. The original file is never modified by this call.
    public func saveAs(
        _ contents: Data,
        to destination: URL,
        overwrite: Bool = false
    ) throws -> DocumentSession {
        try ensureOpen()
        guard destination.isFileURL else { throw DocumentStoreError.notAFileURL }
        guard destination.standardizedFileURL != url.standardizedFileURL else {
            throw DocumentStoreError.unsupportedFileSituation(.sameFileAsCurrent, destination)
        }

        // A save panel hands back a security-scoped URL for the new location.
        let newLease = SecurityScopeLease(url: destination, access: access)
        do {
            let status = try io.status(of: destination)
            if status.exists {
                guard overwrite else { throw DocumentStoreError.targetExists(destination) }
                // Overwriting an existing file is an explicit user choice, but
                // the same structural refusals still apply.
                try Self.validateSaveTarget(status, url: destination)
            } else {
                try Self.validateCreatableDestination(destination)
            }

            let staging = try io.createStagingFile(nextTo: destination, contents: contents)
            var committed = false
            defer {
                if !committed {
                    try? io.removeItemIfExists(at: staging)
                }
            }

            let finalURL = try io.withCoordinatedWrite(at: destination) { coordinatedURL in
                let liveStatus = try io.status(of: coordinatedURL)
                if liveStatus.exists {
                    guard overwrite else { throw DocumentStoreError.targetExists(coordinatedURL) }
                    try Self.validateSaveTarget(liveStatus, url: coordinatedURL)
                    return try io.replaceItem(at: coordinatedURL, with: staging)
                }
                // A file that did not exist is created, never "replaced".
                try io.moveItem(at: staging, to: coordinatedURL)
                // The staging file is created 0600 for safety. A brand-new
                // document should look like any other document, so it gets
                // ordinary permissions; an existing target keeps its own,
                // because replaceItemAt preserves the original's metadata.
                try? io.setPermissions(0o644, at: coordinatedURL)
                return coordinatedURL
            }

            committed = true
            let version = try io.version(of: finalURL)
            return DocumentSession(
                url: finalURL,
                version: version,
                isWritableAtOpen: true,
                lease: newLease,
                io: io,
                access: access
            )
        } catch {
            newLease.release()
            throw error
        }
    }

    /// Releases the security scope. Safe to call more than once.
    public func close() {
        // Wait for an in-flight save: releasing access mid-write would turn a
        // recoverable failure into an unclear one.
        saveLock.lock()
        defer { saveLock.unlock() }

        let alreadyClosed = stateLock.withLock { () -> Bool in
            if closed { return true }
            closed = true
            return false
        }
        guard !alreadyClosed else { return }
        lease.release()
    }

    // MARK: - Decisions

    private func ensureOpen() throws {
        if isClosed { throw DocumentStoreError.sessionClosed }
    }

    /// Identity first: a new inode means the file was replaced, whatever the
    /// bytes look like. Then content, because a file can be rewritten with the
    /// same size and its mtime restored.
    static func classify(expected: DocumentVersion, current: DocumentVersion) -> ExternalChange {
        if current.identity != expected.identity {
            return .replaced(current)
        }
        if current.size != expected.size || current.contentHash != expected.contentHash {
            return .modified(current)
        }
        return .unchanged
    }

    private static func validateSaveTarget(_ status: FileStatus, url: URL) throws {
        guard status.exists else { throw DocumentStoreError.fileMissing(url) }
        if status.isSymbolicLink {
            // replaceItemAt would replace the link itself, not its target.
            throw DocumentStoreError.unsupportedFileSituation(.symbolicLink, url)
        }
        guard status.isRegularFile else {
            throw DocumentStoreError.unsupportedFileSituation(.notARegularFile, url)
        }
        if status.linkCount > 1 {
            // Replacing one name would silently detach it from the others:
            // verified that replaceItemAt splits a hard link (nlink 2 -> 1).
            throw DocumentStoreError.unsupportedFileSituation(.hardLink(linkCount: status.linkCount), url)
        }
        if status.isCloudPlaceholder {
            throw DocumentStoreError.unsupportedFileSituation(.cloudPlaceholderNotDownloaded, url)
        }
        guard status.isWritable else { throw DocumentStoreError.readOnly(url) }
    }

    private static func validateCreatableDestination(_ destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw DocumentStoreError.fileMissing(directory)
        }
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            throw DocumentStoreError.permissionDenied(directory)
        }
    }
}
