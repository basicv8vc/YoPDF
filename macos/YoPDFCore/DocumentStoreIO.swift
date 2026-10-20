import CryptoKit
import Foundation

/// The filesystem operations `DocumentStore` needs, behind one seam.
///
/// It exists so failure paths can be exercised for real: a test can make the
/// staging write fail or the replacement fail and then assert that the
/// original file is byte-for-byte unchanged. It is one seam for the whole save
/// pipeline, not one abstraction per error case.
public protocol DocumentStoreIO: Sendable {
    func status(of url: URL) throws -> FileStatus
    /// Reads identity, size, mtime and a streaming SHA-256 of the contents.
    func version(of url: URL) throws -> DocumentVersion
    func readContents(of url: URL) throws -> Data
    /// Creates a sibling staging file, writes `contents`, flushes it to disk,
    /// and returns it with the hash of what was written. If it throws, no
    /// staging file is left behind.
    func createStagingFile(nextTo url: URL, contents: Data) throws -> StagedFile
    /// Runs `body` inside an `NSFileCoordinator` write intent.
    func withCoordinatedWrite(at url: URL, _ body: (URL) throws -> URL) throws -> URL
    /// Atomically replaces `url` with `staged` and returns the resulting URL.
    ///
    /// A failure is reported as `.replacementStateUncertain` carrying whatever
    /// survived, because `replaceItemAt` may have moved the original aside
    /// before failing. It is never safe to assume the target is unchanged.
    func replaceItem(at url: URL, with staged: StagedFile, expecting expected: DocumentVersion) throws -> URL
    func moveItem(at url: URL, to destination: URL) throws
    /// Applies POSIX permissions. Used only for files this store creates, so a
    /// new document gets normal document permissions instead of the 0600 the
    /// staging file is created with.
    func setPermissions(_ mode: Int, at url: URL) throws
    func removeItemIfExists(at url: URL) throws
}

/// The real implementation. Uses POSIX for identity and flushing, and
/// `FileManager` for the replacement itself.
public struct SystemDocumentStoreIO: DocumentStoreIO {

    /// 1 MiB keeps hashing of a 200 MB file at constant memory.
    static let hashChunkSize = 1 << 20

    public init() {}

    // MARK: - Inspection

    public func status(of url: URL) throws -> FileStatus {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return .missing }
            throw DocumentStoreError.fromPOSIX(
                code,
                url: url,
                fallback: .notReadable(url, DocumentStoreError.message(forPOSIX: code))
            )
        }

        let isSymbolicLink = (info.st_mode & S_IFMT) == S_IFLNK
        if isSymbolicLink {
            var resolved = stat()
            guard url.path.withCString({ stat($0, &resolved) }) == 0 else {
                // A dangling symlink: the path exists, but no file is reachable.
                return FileStatus(
                    exists: false,
                    isRegularFile: false,
                    isSymbolicLink: true,
                    linkCount: 0,
                    isWritable: false,
                    isCloudPlaceholder: false
                )
            }
            return makeStatus(from: resolved, isSymbolicLink: true, url: url)
        }
        return makeStatus(from: info, isSymbolicLink: false, url: url)
    }

    private func makeStatus(from info: stat, isSymbolicLink: Bool, url: URL) -> FileStatus {
        FileStatus(
            exists: true,
            isRegularFile: (info.st_mode & S_IFMT) == S_IFREG,
            isSymbolicLink: isSymbolicLink,
            linkCount: Int(info.st_nlink),
            isWritable: FileManager.default.isWritableFile(atPath: url.path),
            isCloudPlaceholder: Self.isCloudPlaceholder(url)
        )
    }

    private static func isCloudPlaceholder(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        ), values.isUbiquitousItem == true else {
            // Non-iCloud providers expose no reliable public "dataless" signal;
            // see the P1 report for this stated limitation.
            return false
        }
        return values.ubiquitousItemDownloadingStatus != .current
    }

    public func version(of url: URL) throws -> DocumentVersion {
        var info = stat()
        guard url.path.withCString({ stat($0, &info) }) == 0 else {
            let code = errno
            throw DocumentStoreError.fromPOSIX(
                code,
                url: url,
                fallback: .notReadable(url, DocumentStoreError.message(forPOSIX: code))
            )
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw DocumentStoreError.unsupportedFileSituation(.notARegularFile, url)
        }
        return DocumentVersion(
            identity: FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino)),
            size: Int64(info.st_size),
            modificationDate: Date(
                timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                    + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
            ),
            contentHash: try Self.sha256Hex(of: url)
        )
    }

    /// Streams the file through SHA-256; never materialises it in memory.
    ///
    /// Uses `read(2)` into one reusable buffer rather than `FileHandle`:
    /// `FileHandle.read(upToCount:)` returns autoreleased `Data` objects, and
    /// a tight loop over a 200 MB file accumulated the whole file in the
    /// autorelease pool before it drained. That is exactly the "read the whole
    /// PDF just to detect a change" behaviour this is meant to avoid.
    static func sha256Hex(of url: URL) throws -> String {
        let descriptor = url.path.withCString { open($0, O_RDONLY) }
        guard descriptor >= 0 else {
            let code = errno
            throw DocumentStoreError.fromPOSIX(
                code,
                url: url,
                fallback: .notReadable(url, DocumentStoreError.message(forPOSIX: code))
            )
        }
        defer { close(descriptor) }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: hashChunkSize)

        while true {
            let readCount = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return read(descriptor, base, raw.count)
            }
            if readCount < 0 {
                if errno == EINTR { continue }
                let code = errno
                throw DocumentStoreError.fromPOSIX(
                    code,
                    url: url,
                    fallback: .notReadable(url, DocumentStoreError.message(forPOSIX: code))
                )
            }
            if readCount == 0 { break }
            buffer.withUnsafeBytes { raw in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw[0..<readCount]))
            }
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func readContents(of url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw Self.mapReadError(error, url: url)
        }
    }

    private static func mapReadError(_ error: Error, url: URL) -> DocumentStoreError {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            let code = Int32(nsError.code)
            return DocumentStoreError.fromPOSIX(
                code,
                url: url,
                fallback: .notReadable(url, DocumentStoreError.message(forPOSIX: code))
            )
        }
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return .fileMissing(url)
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return .permissionDenied(url)
            default:
                break
            }
        }
        return .notReadable(url, error.localizedDescription)
    }

    // MARK: - Writing

    public func createStagingFile(nextTo url: URL, contents: Data) throws -> StagedFile {
        let directory = url.deletingLastPathComponent()
        // Same directory means same volume, which is what makes the later
        // rename a single atomic step instead of a copy.
        let stagingURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).yopdf-\(UUID().uuidString).staging"
        )

        let descriptor = stagingURL.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        }
        guard descriptor >= 0 else {
            let code = errno
            throw DocumentStoreError.fromPOSIX(
                code,
                url: stagingURL,
                fallback: .stagingFailed(DocumentStoreError.message(forPOSIX: code))
            )
        }

        var removeOnFailure = true
        defer {
            close(descriptor)
            if removeOnFailure {
                try? FileManager.default.removeItem(at: stagingURL)
            }
        }

        try Self.writeAll(contents, to: descriptor, url: stagingURL)
        try Self.flushToDisk(descriptor: descriptor, url: stagingURL)
        removeOnFailure = false
        // Hashing the in-memory bytes is one pass and no extra allocation; it
        // lets a failed replacement tell "new content is already installed"
        // from "the original is still there".
        let hash = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
        return StagedFile(url: stagingURL, contentHash: hash)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32, url: URL) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    let code = errno
                    throw DocumentStoreError.fromPOSIX(
                        code,
                        url: url,
                        fallback: .stagingFailed(DocumentStoreError.message(forPOSIX: code))
                    )
                }
                offset += written
            }
        }
    }

    private static func flushToDisk(descriptor: Int32, url: URL) throws {
        guard fsync(descriptor) == 0 else {
            let code = errno
            throw DocumentStoreError.fromPOSIX(
                code,
                url: url,
                fallback: .stagingFailed(DocumentStoreError.message(forPOSIX: code))
            )
        }
        // F_FULLFSYNC asks the drive to flush its own cache. It is not
        // supported on every volume, so a failure here is not fatal: fsync
        // above already handed the bytes to the kernel.
        _ = fcntl(descriptor, F_FULLFSYNC)
    }

    public func withCoordinatedWrite(at url: URL, _ body: (URL) throws -> URL) throws -> URL {
        var coordinationError: NSError?
        var outcome: Result<URL, Error>?

        NSFileCoordinator().coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            // The coordinator does not propagate errors thrown by the accessor,
            // so the result is carried out explicitly.
            outcome = Result { try body(coordinatedURL) }
        }

        if let coordinationError {
            throw DocumentStoreError.coordinationFailed(coordinationError.localizedDescription)
        }
        guard let outcome else {
            throw DocumentStoreError.coordinationFailed("The file coordinator did not run the write block.")
        }
        return try outcome.get()
    }

    public func replaceItem(at url: URL, with staged: StagedFile, expecting expected: DocumentVersion) throws -> URL {
        do {
            // Default options keep the original file's metadata (permissions,
            // owner, extended attributes, ACL). Verified on APFS: mode 0600 and
            // a user xattr survive, while `.usingNewMetadataOnly` drops them.
            let replaced = try FileManager.default.replaceItemAt(url, withItemAt: staged.url)
            Self.synchronizeDirectory(containing: url)
            return replaced ?? url
        } catch {
            throw classifyReplacementFailure(error, target: url, staged: staged, expected: expected)
        }
    }

    /// The documented `NSFileOriginalItemLocationKey`.
    ///
    /// The current macOS SDK does not export this symbol to Swift, but the
    /// runtime uses exactly this string: a real `replaceItemAt` failure prints
    /// it in `userInfo`. It is read here and never written.
    private static let originalItemLocationKey = "NSFileOriginalItemLocationKey"

    private func reportedOriginalLocation(
        in userInfo: [String: Any],
        target: URL,
        staging: URL
    ) -> URL? {
        if let reported = userInfo[Self.originalItemLocationKey] as? URL,
           FileManager.default.fileExists(atPath: reported.path) {
            return reported
        }
        // Fallback for the case where the key is absent or bridged
        // differently: any surviving URL in the error that is neither the
        // target nor the staging file. Reported only; never restored.
        for value in userInfo.values {
            guard let candidate = value as? URL,
                  candidate != target,
                  candidate != staging,
                  FileManager.default.fileExists(atPath: candidate.path) else { continue }
            return candidate
        }
        return nil
    }

    /// A failed `replaceItemAt` is not evidence that nothing changed.
    ///
    /// The API moves the original aside before installing the new item and
    /// reports where it went. Only one outcome is safe to call "unchanged":
    /// the target still exists and still matches the version the caller
    /// expected. Everything else is reported as uncertain, with every
    /// surviving path, and nothing is deleted.
    private func classifyReplacementFailure(
        _ error: Error,
        target: URL,
        staged: StagedFile,
        expected: DocumentVersion
    ) -> DocumentStoreError {
        let nsError = error as NSError
        let survivingLocation = reportedOriginalLocation(
            in: nsError.userInfo,
            target: target,
            staging: staged.url
        )
        let stagingSurvived = FileManager.default.fileExists(atPath: staged.url.path)

        if let current = try? version(of: target),
           current.identity == expected.identity,
           current.contentHash == expected.contentHash {
            // The target is verifiably untouched, so the failure can be named
            // precisely instead of being reported as an unknown state.
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileWriteNoPermissionError || nsError.code == NSFileReadNoPermissionError {
                return .permissionDenied(target)
            }
            return .replacementFailed(nsError.localizedDescription)
        }

        return .replacementStateUncertain(
            ReplacementRecovery(
                targetURL: target,
                stagingURL: stagingSurvived ? staged.url : nil,
                originalLocation: survivingLocation,
                underlyingDescription: nsError.localizedDescription
            )
        )
    }

    public func moveItem(at url: URL, to destination: URL) throws {
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            Self.synchronizeDirectory(containing: destination)
        } catch {
            throw DocumentStoreError.replacementFailed(error.localizedDescription)
        }
    }

    public func setPermissions(_ mode: Int, at url: URL) throws {
        do {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        } catch {
            throw DocumentStoreError.permissionDenied(url)
        }
    }

    public func removeItemIfExists(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Best effort: makes the rename itself durable. There is nothing useful
    /// to report to the caller if a directory fsync fails.
    private static func synchronizeDirectory(containing url: URL) {
        let directory = url.deletingLastPathComponent().path
        let descriptor = directory.withCString { open($0, O_RDONLY) }
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        close(descriptor)
    }
}
