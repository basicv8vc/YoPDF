import XCTest
@testable import YoPDFCore

/// The save contract: what is written, what is preserved, and what is refused.
final class DocumentStoreSaveTests: XCTestCase {

    private var directory: TemporaryDirectory!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory("save")
    }

    override func tearDown() {
        directory?.remove()
        directory = nil
        super.tearDown()
    }

    private func makeFile(_ name: String = "doc.pdf", bytes: Data? = nil) throws -> (URL, Data) {
        let payload = bytes ?? TestPayload.bytes(4096)
        let url = try directory.write(name, payload)
        return (url, payload)
    }

    private func inode(_ url: URL) -> NSNumber? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber]) as? NSNumber
    }

    private func mode(_ url: URL) -> NSNumber? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
    }

    @discardableResult
    private func setExtendedAttribute(_ value: String, named name: String, at url: URL) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.withUnsafeBufferPointer {
            setxattr(url.path, name, $0.baseAddress, $0.count, 0, 0)
        } == 0
    }

    private func extendedAttribute(named name: String, at url: URL) -> String? {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(url.path, name, &buffer, size, 0, 0)
        guard read > 0 else { return nil }
        return String(bytes: buffer.prefix(read), encoding: .utf8)
    }

    // MARK: - Successful saves

    func testSaveReplacesContentsAndUpdatesTheSessionVersion() throws {
        let (url, original) = try makeFile()
        let session = try DocumentStore().open(url)
        defer { session.close() }
        let originalInode = inode(url)

        let updated = TestPayload.bytes(5000, seed: 0x77)
        try session.save(updated)

        XCTAssertEqual(try Data(contentsOf: url), updated)
        XCTAssertNotEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(session.version.contentHash, TestPayload.sha256(updated))
        XCTAssertEqual(session.version.size, Int64(updated.count))
        XCTAssertNotEqual(inode(url), originalInode, "an atomic replacement installs a new inode")
        XCTAssertEqual(session.version.identity.inode, inode(url)?.uint64Value)
    }

    func testReopenedFileContainsExactlyWhatWasSaved() throws {
        let (url, _) = try makeFile()
        let updated = TestPayload.bytes(12345, seed: 0x22)

        let writer = try DocumentStore().open(url)
        try writer.save(updated)
        writer.close()

        let reader = try DocumentStore().open(url)
        defer { reader.close() }
        XCTAssertEqual(try reader.read(), updated)
        XCTAssertEqual(try reader.checkExternalChange(), .unchanged)
    }

    func testSecondSaveOnTheSameSessionSucceeds() throws {
        let (url, _) = try makeFile()
        let session = try DocumentStore().open(url)
        defer { session.close() }

        let first = TestPayload.bytes(100, seed: 0x11)
        let second = TestPayload.bytes(200, seed: 0x22)
        try session.save(first)
        try session.save(second)

        XCTAssertEqual(try Data(contentsOf: url), second)
    }

    func testSavePreservesPermissionsAndExtendedAttributes() throws {
        let (url, _) = try makeFile()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertTrue(setExtendedAttribute("keep-me", named: "user.yopdf.test", at: url))

        let session = try DocumentStore().open(url)
        try session.save(TestPayload.bytes(777, seed: 0x33))
        session.close()

        XCTAssertEqual(mode(url)?.intValue, 0o600, "the original file's mode must survive the replacement")
        XCTAssertEqual(extendedAttribute(named: "user.yopdf.test", at: url), "keep-me")
    }

    // MARK: - Refusing to overwrite external changes

    func testSaveRefusesWhenBytesChangedWithSameSizeAndRestoredModificationDate() throws {
        let payload = TestPayload.bytes(8192, seed: 0x41)
        let (url, _) = try makeFile(bytes: payload)
        let session = try DocumentStore().open(url)
        defer { session.close() }
        let openedVersion = session.version

        let external = TestPayload.bytes(8192, seed: 0x99)
        try external.write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: openedVersion.modificationDate],
            ofItemAtPath: url.path
        )

        let error = storeError(from: try session.save(TestPayload.bytes(32)))

        guard case let .externalModificationDetected(change) = error else {
            return XCTFail("expected a detected external modification, got \(String(describing: error))")
        }
        guard case let .modified(version) = change else {
            return XCTFail("expected .modified, got \(change)")
        }
        XCTAssertEqual(version.contentHash, TestPayload.sha256(external))
        XCTAssertEqual(try Data(contentsOf: url), external, "the external bytes must survive untouched")
        XCTAssertEqual(directory.stagingLeftovers(), [])
        XCTAssertEqual(session.version, openedVersion, "a failed save must not advance the baseline")
    }

    func testSaveRefusesWhenFileWasReplacedByADifferentFile() throws {
        let (url, payload) = try makeFile()
        let session = try DocumentStore().open(url)
        defer { session.close() }

        // Same bytes, new inode: the file is not the one the session opened.
        try FileManager.default.removeItem(at: url)
        try payload.write(to: url)

        let error = storeError(from: try session.save(TestPayload.bytes(64)))

        guard case let .externalModificationDetected(change) = error, case .replaced = change else {
            return XCTFail("expected .replaced, got \(String(describing: error))")
        }
        XCTAssertEqual(try Data(contentsOf: url), payload)
    }

    func testSaveRefusesWhenFileWasDeletedAndDoesNotRecreateIt() throws {
        let (url, _) = try makeFile()
        let session = try DocumentStore().open(url)
        defer { session.close() }

        try FileManager.default.removeItem(at: url)

        let error = storeError(from: try session.save(TestPayload.bytes(64)))

        XCTAssertEqual(error, .fileMissing(url))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "a deleted original must never be resurrected by a save"
        )
        XCTAssertEqual(directory.stagingLeftovers(), [])
    }

    // MARK: - Permission failures

    func testReadOnlyFileIsRefusedAndKeepsItsBytes() throws {
        let (url, payload) = try makeFile()
        let session = try DocumentStore().open(url)
        defer { session.close() }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        let error = storeError(from: try session.save(TestPayload.bytes(64)))

        XCTAssertEqual(error, .readOnly(url))
        XCTAssertEqual(try Data(contentsOf: url), payload)
    }

    func testReadOnlyDirectoryFailsStagingWithoutTouchingTheFile() throws {
        let (url, payload) = try makeFile()
        let session = try DocumentStore().open(url)
        defer { session.close() }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.url.path) }

        let error = storeError(from: try session.save(TestPayload.bytes(64)))

        guard case .permissionDenied = error else {
            return XCTFail("expected .permissionDenied, got \(String(describing: error))")
        }
        XCTAssertEqual(try Data(contentsOf: url), payload)
    }

    // MARK: - Two sessions on one file

    func testSecondSessionCannotOverwriteTheFirstSessionsSave() throws {
        let (url, original) = try makeFile()
        let first = try DocumentStore().open(url)
        let second = try DocumentStore().open(url)
        defer {
            first.close()
            second.close()
        }

        let fromFirst = TestPayload.bytes(300, seed: 0x51)
        try first.save(fromFirst)

        let error = storeError(from: try second.save(TestPayload.bytes(300, seed: 0x62)))

        guard case let .externalModificationDetected(change) = error, case .replaced = change else {
            return XCTFail("expected .replaced, got \(String(describing: error))")
        }
        XCTAssertEqual(try Data(contentsOf: url), fromFirst)
        XCTAssertNotEqual(try Data(contentsOf: url), original)
    }

    func testSaveAfterCloseIsRejected() throws {
        let (url, payload) = try makeFile()
        let session = try DocumentStore().open(url)
        session.close()

        let error = storeError(from: try session.save(TestPayload.bytes(64)))

        XCTAssertEqual(error, .sessionClosed)
        XCTAssertEqual(try Data(contentsOf: url), payload)
    }

    // MARK: - Save As

    func testSaveAsNewPathWritesTheCopyAndLeavesTheOriginalAlone() throws {
        let (url, payload) = try makeFile()
        let session = try DocumentStore().open(url)
        defer { session.close() }
        let destination = directory.url.appendingPathComponent("copy.pdf")
        let contents = TestPayload.bytes(2048, seed: 0x71)

        let copy = try session.saveAs(contents, to: destination)
        defer { copy.close() }

        XCTAssertEqual(try Data(contentsOf: destination), contents)
        XCTAssertEqual(try Data(contentsOf: url), payload, "Save As must not touch the original")
        XCTAssertEqual(copy.url, destination)
        XCTAssertEqual(copy.version.contentHash, TestPayload.sha256(contents))
        XCTAssertEqual(mode(destination)?.intValue, 0o644, "a new document gets ordinary permissions")
        XCTAssertEqual(session.url, url, "the original session keeps pointing at the original")
    }

    func testSaveAsToExistingPathWithoutOverwriteIsRefused() throws {
        let (url, payload) = try makeFile()
        let session = try DocumentStore().open(url)
        defer { session.close() }
        let existing = try directory.write("existing.pdf", TestPayload.bytes(999, seed: 0x81))

        let error = storeError(from: try session.saveAs(TestPayload.bytes(10), to: existing))

        XCTAssertEqual(error, .targetExists(existing))
        XCTAssertEqual(try Data(contentsOf: existing), TestPayload.bytes(999, seed: 0x81))
        XCTAssertEqual(try Data(contentsOf: url), payload)
    }

    func testSaveAsToExistingPathWithOverwriteReplacesIt() throws {
        let (url, _) = try makeFile()
        let session = try DocumentStore().open(url)
        defer { session.close() }
        let existing = try directory.write("existing.pdf", TestPayload.bytes(999, seed: 0x81))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: existing.path)
        let contents = TestPayload.bytes(321, seed: 0x91)

        let copy = try session.saveAs(contents, to: existing, overwrite: true)
        defer { copy.close() }

        XCTAssertEqual(try Data(contentsOf: existing), contents)
        XCTAssertEqual(
            mode(existing)?.intValue,
            0o600,
            "overwriting keeps the replaced file's permissions"
        )
    }

    func testSaveAsOntoTheOpenFileIsRefused() throws {
        let (url, payload) = try makeFile()
        let session = try DocumentStore().open(url)
        defer { session.close() }

        let error = storeError(from: try session.saveAs(TestPayload.bytes(10), to: url, overwrite: true))

        XCTAssertEqual(error, .unsupportedFileSituation(.sameFileAsCurrent, url))
        XCTAssertEqual(try Data(contentsOf: url), payload)
    }

    func testSaveAsIntoMissingDirectoryIsRefused() throws {
        let (url, _) = try makeFile()
        let session = try DocumentStore().open(url)
        defer { session.close() }
        let missingDirectory = directory.url.appendingPathComponent("nope", isDirectory: true)
        let destination = missingDirectory.appendingPathComponent("copy.pdf")

        let error = storeError(from: try session.saveAs(TestPayload.bytes(10), to: destination))

        XCTAssertEqual(error, .fileMissing(missingDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testSaveAsAcquiresAndReleasesItsOwnScope() throws {
        let (url, _) = try makeFile()
        let spy = SecurityScopeSpy()
        let store = DocumentStore(access: spy)
        let session = try store.open(url)
        let destination = directory.url.appendingPathComponent("copy.pdf")

        let copy = try session.saveAs(TestPayload.bytes(10), to: destination)
        XCTAssertEqual(spy.starts, [url, destination])
        XCTAssertEqual(spy.stops, [], "both sessions are still open")

        session.close()
        copy.close()
        XCTAssertEqual(spy.stops, [url, destination])
    }
}
