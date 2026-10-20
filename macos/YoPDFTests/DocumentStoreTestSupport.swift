import CryptoKit
import Foundation
import XCTest
@testable import YoPDFCore

/// A disposable directory per test. Tests never touch a real user document.
final class TemporaryDirectory {
    let url: URL

    init(_ label: String = "document-store") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("YoPDF-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ name: String, _ data: Data) throws -> URL {
        let fileURL = url.appendingPathComponent(name)
        try data.write(to: fileURL)
        return fileURL
    }

    func remove() {
        // A read-only directory or file left behind by a test must not turn
        // cleanup into a failure, so permissions are restored first.
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
            for entry in entries {
                let path = url.appendingPathComponent(entry).path
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            }
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }

    /// Files the store may leave behind if a save is not cleaned up properly.
    func stagingLeftovers() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return entries.filter { $0.contains(".yopdf-") && $0.hasSuffix(".staging") }
    }
}

enum TestPayload {
    /// Deterministic bytes, distinguishable per seed.
    static func bytes(_ count: Int, seed: UInt8 = 0x41) -> Data {
        Data((0..<count).map { UInt8((Int(seed) + $0) % 251) })
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Wraps the real filesystem implementation and fails one chosen step.
///
/// This is the single seam used for failure injection: the real staging,
/// coordination and replacement code still runs for every other step, so the
/// assertions are about the actual save pipeline, not a mock of it.
final class ScriptedDocumentStoreIO: DocumentStoreIO, @unchecked Sendable {
    enum Failure: Equatable {
        case staging
        case replacement
        case coordination
    }

    /// How `replaceItem` should fail. Each case reproduces a different outcome
    /// of a replacement that did not complete cleanly.
    enum PartialCommit: Equatable {
        /// Reports an error without touching anything: the ambiguous case.
        case nothingChanged
        /// Moves the original aside first, then reports an error — the state
        /// `NSFileOriginalItemLocationKey` exists for.
        case originalMovedTo(URL)
        /// Installs the new content, then reports an error anyway.
        case newContentInstalled
    }

    private let base = SystemDocumentStoreIO()
    private let lock = NSLock()
    private var failure: Failure?
    private var replacements = 0
    private var commits = 0
    private var versionFailureAfterCommit = false
    private var partial: PartialCommit?
    private var hook: (@Sendable () -> Void)?

    var failAt: Failure? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }

    /// Runs just before the coordinated write body, which is where a test can
    /// simulate another app changing the file after the user confirmed.
    var beforeCoordinatedWrite: (@Sendable () -> Void)? {
        get { lock.withLock { hook } }
        set { lock.withLock { hook = newValue } }
    }

    var partialCommit: PartialCommit? {
        get { lock.withLock { partial } }
        set { lock.withLock { partial = newValue } }
    }

    /// Makes `version(of:)` fail once a commit has happened, which is the
    /// post-commit failure a save has to report without claiming nothing changed.
    var failVersionAfterCommit: Bool {
        get { lock.withLock { versionFailureAfterCommit } }
        set { lock.withLock { versionFailureAfterCommit = newValue } }
    }

    var replacementCount: Int {
        lock.withLock { replacements }
    }

    func status(of url: URL) throws -> FileStatus {
        try base.status(of: url)
    }

    func version(of url: URL) throws -> DocumentVersion {
        if failVersionAfterCommit, lock.withLock({ commits }) > 0 {
            throw DocumentStoreError.notReadable(url, "injected version failure after commit")
        }
        return try base.version(of: url)
    }

    func readContents(of url: URL) throws -> Data {
        try base.readContents(of: url)
    }

    func createStagingFile(nextTo url: URL, contents: Data) throws -> StagedFile {
        if failAt == .staging {
            throw DocumentStoreError.stagingFailed("injected staging failure")
        }
        return try base.createStagingFile(nextTo: url, contents: contents)
    }

    func withCoordinatedWrite(at url: URL, _ body: (URL) throws -> URL) throws -> URL {
        if failAt == .coordination {
            throw DocumentStoreError.coordinationFailed("injected coordination failure")
        }
        beforeCoordinatedWrite?()
        return try base.withCoordinatedWrite(at: url, body)
    }

    func replaceItem(at url: URL, with staged: StagedFile, expecting expected: DocumentVersion) throws -> URL {
        if failAt == .replacement {
            throw DocumentStoreError.replacementFailed("injected replacement failure")
        }

        if let partial = partialCommit {
            switch partial {
            case .nothingChanged:
                throw DocumentStoreError.replacementStateUncertain(
                    ReplacementRecovery(
                        targetURL: url,
                        stagingURL: staged.url,
                        originalLocation: nil,
                        underlyingDescription: "injected ambiguous failure"
                    )
                )
            case let .originalMovedTo(backup):
                try base.moveItem(at: url, to: backup)
                throw DocumentStoreError.replacementStateUncertain(
                    ReplacementRecovery(
                        targetURL: url,
                        stagingURL: staged.url,
                        originalLocation: backup,
                        underlyingDescription: "injected partial commit: original moved"
                    )
                )
            case .newContentInstalled:
                _ = try base.replaceItem(at: url, with: staged, expecting: expected)
                lock.withLock { commits += 1 }
                throw DocumentStoreError.replacementStateUncertain(
                    ReplacementRecovery(
                        targetURL: url,
                        stagingURL: nil,
                        originalLocation: nil,
                        underlyingDescription: "injected partial commit: new content installed"
                    )
                )
            }
        }

        let result = try base.replaceItem(at: url, with: staged, expecting: expected)
        lock.withLock {
            replacements += 1
            commits += 1
        }
        return result
    }

    func moveItem(at url: URL, to destination: URL) throws {
        try base.moveItem(at: url, to: destination)
        lock.withLock { commits += 1 }
    }

    func setPermissions(_ mode: Int, at url: URL) throws {
        try base.setPermissions(mode, at: url)
    }

    func removeItemIfExists(at url: URL) throws {
        try base.removeItemIfExists(at: url)
    }
}

/// Blocks inside `readContents` until the test lets it finish, so a close that
/// races with a read can be checked without sleeps or luck.
final class BlockingReadIO: DocumentStoreIO, @unchecked Sendable {
    private let base = SystemDocumentStoreIO()
    private let lock = NSLock()
    private var log: [String] = []

    let readStarted = DispatchSemaphore(value: 0)
    let allowReadToFinish = DispatchSemaphore(value: 0)

    var events: [String] {
        lock.withLock { log }
    }

    private func record(_ event: String) {
        lock.withLock { log.append(event) }
    }

    func status(of url: URL) throws -> FileStatus { try base.status(of: url) }
    func version(of url: URL) throws -> DocumentVersion { try base.version(of: url) }

    func readContents(of url: URL) throws -> Data {
        record("readStarted")
        readStarted.signal()
        allowReadToFinish.wait()
        record("readFinished")
        return try base.readContents(of: url)
    }

    func createStagingFile(nextTo url: URL, contents: Data) throws -> StagedFile {
        try base.createStagingFile(nextTo: url, contents: contents)
    }

    func withCoordinatedWrite(at url: URL, _ body: (URL) throws -> URL) throws -> URL {
        try base.withCoordinatedWrite(at: url, body)
    }

    func replaceItem(at url: URL, with staged: StagedFile, expecting expected: DocumentVersion) throws -> URL {
        try base.replaceItem(at: url, with: staged, expecting: expected)
    }

    func moveItem(at url: URL, to destination: URL) throws {
        try base.moveItem(at: url, to: destination)
    }

    func setPermissions(_ mode: Int, at url: URL) throws {
        try base.setPermissions(mode, at: url)
    }

    func removeItemIfExists(at url: URL) throws {
        try base.removeItemIfExists(at: url)
    }
}

extension XCTestCase {
    /// Runs a throwing expression and returns the store error, if any.
    func storeError<T>(from expression: @autoclosure () throws -> T) -> DocumentStoreError? {
        do {
            _ = try expression()
            return nil
        } catch let error as DocumentStoreError {
            return error
        } catch {
            return nil
        }
    }

    /// Heap bytes currently allocated by this process.
    ///
    /// Preferred over the physical footprint for "did we load the file?":
    /// reading a file also pulls its pages into the process's file-backed
    /// resident set, which is reclaimable cache, not an allocation.
    func heapBytesInUse() -> UInt64 {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(malloc_default_zone(), &statistics)
        return UInt64(statistics.size_in_use)
    }

    /// Physical memory currently attributed to this process. Used to prove the
    /// hashing path does not materialise a large file.
    func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
