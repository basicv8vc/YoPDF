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

    /// What the session can still be trusted for.
    public enum State: Equatable, Sendable {
        /// The baseline matches what the session last observed on disk.
        case open
        /// A save committed, or stopped in an unclear state, and the session
        /// could not confirm the resulting version. Only `refresh()` and
        /// `close()` are allowed until it is resolved.
        case needsRefresh
        case closed
    }

    /// Guards `currentURL`, `currentVersion`, `state` and `lease`.
    private let stateLock = NSLock()
    /// Held for the whole of every file operation and of `close()`.
    ///
    /// This is what keeps `close()` from releasing the security scope while a
    /// read or a save is still using it. Lock order is always
    /// `operationLock` → `stateLock`; nothing takes them the other way round.
    private let operationLock = NSLock()

    /// What a save was trying to produce, recorded only while the session is in
    /// `needsRefresh`.
    ///
    /// Without it, `refresh()` could only answer "is there a file here?", and
    /// would happily adopt a file some other program created at the same path.
    /// Both reasons for entering `needsRefresh` (an undecidable commit and a
    /// commit whose version could not be read back) resolve the same way: the
    /// disk must hold either the content the save intended or the original the
    /// save was told to expect.
    struct PendingSave: Equatable, Sendable {
        /// The version the file had before the save.
        let original: DocumentVersion
        /// Hash of the bytes the save tried to write.
        let intendedHash: String
    }

    private var lease: SecurityScopeLease
    private let io: any DocumentStoreIO
    private let access: any SecurityScopeAccessing

    private var currentURL: URL
    private var currentVersion: DocumentVersion
    private var currentState: State = .open
    private var pendingSave: PendingSave?

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
        // A session must not be deallocated while an operation is running;
        // callers hold it for the duration of the call. Releasing here only
        // balances an open that was never explicitly closed.
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

    public var state: State {
        stateLock.withLock { currentState }
    }

    public var isClosed: Bool {
        stateLock.withLock { currentState == .closed }
    }

    // MARK: - Reading

    public func read() throws -> Data {
        operationLock.lock()
        defer { operationLock.unlock() }
        try ensureUsable()

        let target = url
        do {
            return try io.readContents(of: target)
        } catch let error as DocumentStoreError {
            throw error
        } catch {
            throw DocumentStoreError.notReadable(target, error.localizedDescription)
        }
    }

    /// Compares the file on disk with the version this session opened.
    ///
    /// Throws only when the file cannot be inspected at all (permission,
    /// unreadable). A file that is simply gone returns `.missing` rather than
    /// throwing, because that is a normal answer to "has it changed?".
    public func checkExternalChange() throws -> ExternalChange {
        operationLock.lock()
        defer { operationLock.unlock() }
        try ensureUsable()

        let target = url
        let status = try io.status(of: target)
        guard status.exists else { return .missing }
        let onDisk = try io.version(of: target)
        return Self.classify(expected: version, current: onDisk)
    }

    /// Re-reads the file's version after a save whose result could not be
    /// confirmed. Returns the session to `.open` only when what is on disk
    /// matches something the save was allowed to produce.
    ///
    /// A session in `needsRefresh` knows two acceptable outcomes: the bytes it
    /// tried to write, or the original it was asked to preserve. Anything else
    /// at that path was written by somebody else, and adopting it would be a
    /// silent way around the external-change check — so the session stays in
    /// `needsRefresh` and the conflict is reported. Resolving that conflict is
    /// a deliberate caller decision (keep mine / keep theirs), not something
    /// this method may decide.
    @discardableResult
    public func refresh() throws -> DocumentVersion {
        operationLock.lock()
        defer { operationLock.unlock() }

        // Refreshing a closed session would silently reopen it, and the scope
        // has already been released.
        if isClosed { throw DocumentStoreError.sessionClosed }

        let target = url
        let pending = stateLock.withLock { pendingSave }

        guard state == .needsRefresh else {
            let updated = try io.version(of: target)
            adopt(updated)
            return updated
        }

        guard let pending else {
            // No expectation was recorded, so there is nothing to verify
            // against and no honest way to call the baseline known.
            throw DocumentStoreError.sessionNeedsRefresh
        }

        // A missing or unreadable target throws here; the session stays in
        // `needsRefresh` because the outcome is still undecided.
        let current = try io.version(of: target)

        if current.contentHash == pending.intendedHash {
            // The save did land after all.
            adopt(current)
            return current
        }
        if current.identity == pending.original.identity,
           current.contentHash == pending.original.contentHash {
            // The save did not land; the original is still there.
            adopt(current)
            return current
        }

        throw DocumentStoreError.externalModificationDetected(
            Self.classify(expected: pending.original, current: current)
        )
    }

    private func adopt(_ version: DocumentVersion) {
        stateLock.withLock {
            currentVersion = version
            currentState = .open
            pendingSave = nil
        }
    }

    // MARK: - Writing

    /// Writes `contents` back to the file this session was opened with.
    ///
    /// The original is never modified until the replacement step, and that
    /// step only runs when the file still matches the version this session
    /// opened. A detected conflict, a staging failure or a failed commit with
    /// the original verifiably in place leaves the original bytes untouched.
    /// A commit that fails in an unclear state is reported as such, keeps every
    /// surviving copy, and puts the session into `needsRefresh`.
    ///
    /// Any error coming out of the coordinated write is checked against the
    /// disk before it is treated as "not committed": the coordinator can report
    /// a problem after the accessor already installed the file, and reporting
    /// that as a plain failure would be wrong in the one direction that matters.
    @discardableResult
    public func save(_ contents: Data) throws -> DocumentVersion {
        operationLock.lock()
        defer { operationLock.unlock() }
        try ensureUsable()

        let target = url
        try Self.validateSaveTarget(try io.status(of: target), url: target)

        let expected = version
        let staged = try io.createStagingFile(nextTo: target, contents: contents)

        var committed = false
        var keepStaging = false
        defer {
            // The staging file is consumed by a successful replacement; on
            // every other path it is removed, unless it may be the only
            // surviving copy of something.
            if !committed && !keepStaging {
                try? io.removeItemIfExists(at: staged.url)
            }
        }

        let finalURL: URL
        do {
            finalURL = try io.withCoordinatedWrite(at: target) { coordinatedURL in
                // Everything below runs inside the write intent, immediately
                // before the bytes are swapped. A process that ignores file
                // coordination can still have written between the check above
                // and this point, which is exactly why the check is repeated.
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

                return try io.replaceItem(at: coordinatedURL, with: staged, expecting: expected)
            }
        } catch {
            // Any failure out of the coordinated write may still have committed
            // the new bytes: the coordinator can report an error after the
            // accessor finished, and `replaceItemAt` can fail after it moved
            // files. Check the disk before deciding, so a write that happened
            // is never reported as "nothing changed".
            //
            // If the caller saved identical bytes, the old and the new content
            // hash the same and this reports "committed" even when nothing
            // moved. That is harmless: the file holds exactly what was asked
            // for, and the session adopts whatever version is now on disk.
            if let current = try? io.version(of: target),
               current.contentHash == staged.contentHash {
                committed = true
                adoptLocation(target)
                adopt(current)
                return current
            }

            guard let storeError = error as? DocumentStoreError,
                  case let .replacementStateUncertain(recovery) = storeError else {
                throw error
            }

            // The original is verifiably still in place: a plain failure.
            if let current = try? io.version(of: recovery.targetURL),
               current.identity == expected.identity,
               current.contentHash == expected.contentHash {
                throw DocumentStoreError.replacementFailed(recovery.underlyingDescription)
            }

            // Unknown. Keep every surviving copy, record what this save was
            // supposed to produce, and stop trusting the baseline until the
            // caller resolves it.
            keepStaging = true
            stateLock.withLock {
                currentState = .needsRefresh
                pendingSave = PendingSave(original: expected, intendedHash: staged.contentHash)
            }
            throw error
        }

        committed = true
        return try finishCommit(
            at: finalURL,
            original: expected,
            intendedHash: staged.contentHash
        )
    }

    /// Writes `contents` to `destination` and returns a **new** session for it.
    ///
    /// The receiver is left untouched: the caller decides when to close the
    /// old session. The original file is never modified by this call.
    ///
    /// With `overwrite`, the destination's version is recorded before staging
    /// and re-checked inside the write intent, so a file changed by another app
    /// after the user confirmed is refused rather than silently replaced. A
    /// destination that did not exist at confirmation time but does at commit
    /// time is also refused.
    public func saveAs(
        _ contents: Data,
        to destination: URL,
        overwrite: Bool = false
    ) throws -> DocumentSession {
        operationLock.lock()
        defer { operationLock.unlock() }
        try ensureUsable()

        guard destination.isFileURL else { throw DocumentStoreError.notAFileURL }
        if try isSameFile(as: destination) {
            throw DocumentStoreError.unsupportedFileSituation(.sameFileAsCurrent, destination)
        }

        // A save panel hands back a security-scoped URL for the new location.
        let newLease = SecurityScopeLease(url: destination, access: access)
        do {
            let existing = try io.status(of: destination)
            var expectedTarget: DocumentVersion?
            if existing.exists {
                guard overwrite else { throw DocumentStoreError.targetExists(destination) }
                try Self.validateSaveTarget(existing, url: destination)
                let recorded = try io.version(of: destination)
                if recorded.identity == version.identity {
                    throw DocumentStoreError.unsupportedFileSituation(.sameFileAsCurrent, destination)
                }
                expectedTarget = recorded
            } else {
                try Self.validateCreatableDestination(destination)
            }

            let staged = try io.createStagingFile(nextTo: destination, contents: contents)
            var committed = false
            var keepStaging = false
            defer {
                if !committed && !keepStaging {
                    try? io.removeItemIfExists(at: staged.url)
                }
            }

            let finalURL: URL
            do {
                finalURL = try io.withCoordinatedWrite(at: destination) { coordinatedURL in
                    let liveStatus = try io.status(of: coordinatedURL)

                    if let expectedTarget {
                        guard liveStatus.exists else {
                            // Deleted after the user confirmed: do not recreate
                            // it behind their back.
                            throw DocumentStoreError.fileMissing(coordinatedURL)
                        }
                        guard overwrite else { throw DocumentStoreError.targetExists(coordinatedURL) }
                        try Self.validateSaveTarget(liveStatus, url: coordinatedURL)

                        let current = try io.version(of: coordinatedURL)
                        if current.identity == version.identity {
                            throw DocumentStoreError.unsupportedFileSituation(.sameFileAsCurrent, coordinatedURL)
                        }
                        let change = Self.classify(expected: expectedTarget, current: current)
                        guard case .unchanged = change else {
                            throw DocumentStoreError.externalModificationDetected(change)
                        }
                        return try io.replaceItem(at: coordinatedURL, with: staged, expecting: expectedTarget)
                    }

                    guard !liveStatus.exists else {
                        throw DocumentStoreError.targetAppearedDuringSave(coordinatedURL)
                    }
                    do {
                        try io.moveItem(at: staged.url, to: coordinatedURL)
                    } catch {
                        // A rename is a single step, but verify rather than
                        // assume that a thrown error means nothing landed.
                        if let created = try? io.version(of: coordinatedURL),
                           created.contentHash == staged.contentHash {
                            try? io.setPermissions(0o644, at: coordinatedURL)
                            return coordinatedURL
                        }
                        throw error
                    }
                    // The staging file is created 0600 for safety. A brand-new
                    // document should look like any other document, so it gets
                    // ordinary permissions; an existing target keeps its own,
                    // because replaceItemAt preserves the original's metadata.
                    try? io.setPermissions(0o644, at: coordinatedURL)
                    return coordinatedURL
                }
            } catch {
                // Same rule as `save`: an error out of the coordinated write
                // does not prove the copy was not created. The hash decides.
                if (try? io.version(of: destination))?.contentHash == staged.contentHash {
                    committed = true
                    return try makeSession(at: destination, lease: newLease)
                }

                guard let storeError = error as? DocumentStoreError,
                      case let .replacementStateUncertain(recovery) = storeError else {
                    throw error
                }
                if let expectedTarget,
                   let current = try? io.version(of: recovery.targetURL),
                   current.identity == expectedTarget.identity,
                   current.contentHash == expectedTarget.contentHash {
                    throw DocumentStoreError.replacementFailed(recovery.underlyingDescription)
                }
                keepStaging = true
                throw error
            }

            committed = true
            return try makeSession(at: finalURL, lease: newLease)
        } catch {
            newLease.release()
            throw error
        }
    }

    /// Releases the security scope. Safe to call more than once.
    ///
    /// Waits for any in-flight operation, so the scope is never released while
    /// a read or a save is still using it.
    public func close() {
        operationLock.lock()
        defer { operationLock.unlock() }

        let alreadyClosed = stateLock.withLock { () -> Bool in
            if currentState == .closed { return true }
            currentState = .closed
            return false
        }
        guard !alreadyClosed else { return }
        lease.release()
    }

    // MARK: - Decisions

    /// Called with `operationLock` held, so the state cannot change underneath
    /// it; it still goes through `stateLock` so every read of the state follows
    /// the same lock order.
    private func ensureUsable() throws {
        switch state {
        case .open:
            return
        case .needsRefresh:
            throw DocumentStoreError.sessionNeedsRefresh
        case .closed:
            throw DocumentStoreError.sessionClosed
        }
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

    /// Records the new location after a replacement and moves the security
    /// scope with it. `replaceItemAt` normally returns the same path, but the
    /// lease must follow the file if it does not.
    private func adoptLocation(_ newURL: URL) {
        let previous = stateLock.withLock { () -> SecurityScopeLease? in
            guard newURL != currentURL else { return nil }
            currentURL = newURL
            return lease
        }
        guard let previous else { return }
        // Acquire the new scope before releasing the old one, so the session is
        // never left without access to the file it is now pointing at.
        let replacement = SecurityScopeLease(url: newURL, access: access)
        stateLock.withLock { lease = replacement }
        previous.release()
    }

    /// Reads back the version after a successful replacement. A failure here is
    /// not a failed save: the file was written. It is reported separately and
    /// leaves the session in `needsRefresh`, with the expected outcome recorded
    /// so `refresh()` can verify what it finds instead of trusting it.
    private func finishCommit(
        at finalURL: URL,
        original: DocumentVersion,
        intendedHash: String
    ) throws -> DocumentVersion {
        adoptLocation(finalURL)
        do {
            let updated = try io.version(of: finalURL)
            adopt(updated)
            return updated
        } catch {
            stateLock.withLock {
                currentState = .needsRefresh
                pendingSave = PendingSave(original: original, intendedHash: intendedHash)
            }
            let reason = (error as? DocumentStoreError)?.localizedDescription ?? error.localizedDescription
            throw DocumentStoreError.committedButUnverified(finalURL, reason)
        }
    }

    private func makeSession(at url: URL, lease: SecurityScopeLease) throws -> DocumentSession {
        do {
            let version = try io.version(of: url)
            return DocumentSession(
                url: url,
                version: version,
                isWritableAtOpen: true,
                lease: lease,
                io: io,
                access: access
            )
        } catch {
            let reason = (error as? DocumentStoreError)?.localizedDescription ?? error.localizedDescription
            throw DocumentStoreError.committedButUnverified(url, reason)
        }
    }

    /// True when `destination` reaches the same file as the session, through
    /// any path: a symlink, a symlinked parent directory, `..`, or a hard link.
    private func isSameFile(as destination: URL) throws -> Bool {
        let resolvedDestination = destination.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCurrent = url.resolvingSymlinksInPath().standardizedFileURL
        if resolvedDestination == resolvedCurrent { return true }

        if let existing = try? io.version(of: destination) {
            return existing.identity == version.identity
        }
        return false
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
