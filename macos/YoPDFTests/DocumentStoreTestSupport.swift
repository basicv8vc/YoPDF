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

    private let base = SystemDocumentStoreIO()
    private let lock = NSLock()
    private var failure: Failure?
    private var replacements = 0

    var failAt: Failure? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }

    var replacementCount: Int {
        lock.withLock { replacements }
    }

    func status(of url: URL) throws -> FileStatus {
        try base.status(of: url)
    }

    func version(of url: URL) throws -> DocumentVersion {
        try base.version(of: url)
    }

    func readContents(of url: URL) throws -> Data {
        try base.readContents(of: url)
    }

    func createStagingFile(nextTo url: URL, contents: Data) throws -> URL {
        if failAt == .staging {
            throw DocumentStoreError.stagingFailed("injected staging failure")
        }
        return try base.createStagingFile(nextTo: url, contents: contents)
    }

    func withCoordinatedWrite(at url: URL, _ body: (URL) throws -> URL) throws -> URL {
        if failAt == .coordination {
            throw DocumentStoreError.coordinationFailed("injected coordination failure")
        }
        return try base.withCoordinatedWrite(at: url, body)
    }

    func replaceItem(at url: URL, with stagingURL: URL) throws -> URL {
        if failAt == .replacement {
            throw DocumentStoreError.replacementFailed("injected replacement failure")
        }
        lock.withLock { replacements += 1 }
        return try base.replaceItem(at: url, with: stagingURL)
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
