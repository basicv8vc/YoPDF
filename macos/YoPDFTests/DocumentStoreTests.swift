import XCTest
@testable import YoPDFCore

/// Session lifecycle: what a session owns, what it reads, and how it reports
/// that the file underneath it changed.
final class DocumentStoreTests: XCTestCase {

    private var directory: TemporaryDirectory!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory("store")
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

    // MARK: - Open and read

    func testOpenRecordsVersionAndReadsExactBytes() throws {
        let (url, payload) = try makeFile()
        let store = DocumentStore()

        let session = try store.open(url)

        XCTAssertEqual(session.url, url)
        XCTAssertEqual(session.version.size, Int64(payload.count))
        XCTAssertEqual(session.version.contentHash, TestPayload.sha256(payload))
        XCTAssertEqual(try session.read(), payload)
        XCTAssertFalse(session.isClosed)
        session.close()
    }

    func testReadAfterCloseThrowsSessionClosed() throws {
        let (url, _) = try makeFile()
        let session = try DocumentStore().open(url)
        session.close()

        let error = storeError(from: try session.read())

        XCTAssertEqual(error, .sessionClosed)
    }

    func testCloseIsIdempotentAndBalancesTheScopeOnce() throws {
        let (url, _) = try makeFile()
        let spy = SecurityScopeSpy()
        let session = try DocumentStore(access: spy).open(url)

        session.close()
        session.close()

        XCTAssertEqual(spy.starts, [url])
        XCTAssertEqual(spy.stops, [url], "closing twice must not release twice")
    }

    func testDeallocatingSessionReleasesScope() throws {
        let (url, _) = try makeFile()
        let spy = SecurityScopeSpy()

        var session: DocumentSession? = try DocumentStore(access: spy).open(url)
        XCTAssertNotNil(session)
        XCTAssertEqual(spy.stops, [])

        session = nil

        XCTAssertEqual(spy.stops, [url])
    }

    // MARK: - Open failures

    func testOpeningMissingFileAcquiresThenReleasesScope() throws {
        let missing = directory.url.appendingPathComponent("absent.pdf")
        let spy = SecurityScopeSpy()

        let error = storeError(from: try DocumentStore(access: spy).open(missing))

        XCTAssertEqual(error, .fileMissing(missing))
        XCTAssertEqual(spy.starts, [missing], "access must be opened before the existence check")
        XCTAssertEqual(spy.stops, [missing])
    }

    func testOpeningNonFileURLIsRejectedWithoutTouchingAccess() throws {
        let spy = SecurityScopeSpy()
        let error = storeError(from: try DocumentStore(access: spy).open(URL(string: "https://example.com/a.pdf")!))

        XCTAssertEqual(error, .notAFileURL)
        XCTAssertEqual(spy.events, [])
    }

    func testOpeningDirectoryIsRefused() throws {
        let directoryURL = directory.url.appendingPathComponent("folder.pdf", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let error = storeError(from: try DocumentStore().open(directoryURL))

        XCTAssertEqual(error, .unsupportedFileSituation(.notARegularFile, directoryURL))
    }

    // MARK: - External change detection

    func testUnchangedFileReportsUnchanged() throws {
        let (url, _) = try makeFile()
        let session = try DocumentStore().open(url)
        defer { session.close() }

        XCTAssertEqual(try session.checkExternalChange(), .unchanged)
    }

    /// The case a size/mtime check alone cannot catch: same length, mtime
    /// deliberately restored, different bytes.
    func testSameSizeSameModificationDateIsDetectedAsModified() throws {
        let payload = TestPayload.bytes(8192, seed: 0x41)
        let (url, _) = try makeFile(bytes: payload)
        // A whole-second timestamp round-trips exactly through the attribute
        // API, so "the mtime is unchanged" is a provable precondition rather
        // than an approximate one.
        let pinnedDate = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: pinnedDate], ofItemAtPath: url.path)

        let session = try DocumentStore().open(url)
        defer { session.close() }
        let openedVersion = session.version
        XCTAssertEqual(openedVersion.modificationDate, pinnedDate)

        let replacement = TestPayload.bytes(8192, seed: 0x99)
        XCTAssertEqual(replacement.count, payload.count)
        try replacement.write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: pinnedDate],
            ofItemAtPath: url.path
        )

        let onDisk = try SystemDocumentStoreIO().version(of: url)
        XCTAssertEqual(onDisk.size, openedVersion.size, "precondition: same size")
        XCTAssertEqual(onDisk.modificationDate, pinnedDate, "precondition: same mtime")
        XCTAssertNotEqual(onDisk.contentHash, openedVersion.contentHash, "precondition: different bytes")

        guard case let .modified(version) = try session.checkExternalChange() else {
            return XCTFail("expected .modified")
        }
        XCTAssertEqual(version.contentHash, TestPayload.sha256(replacement))
    }

    func testFileReplacedByAnotherInodeIsDetectedAsReplaced() throws {
        let (url, payload) = try makeFile()
        let session = try DocumentStore().open(url)
        defer { session.close() }

        try FileManager.default.removeItem(at: url)
        try payload.write(to: url)

        guard case .replaced = try session.checkExternalChange() else {
            return XCTFail("expected .replaced")
        }
    }

    func testDeletedFileReportsMissing() throws {
        let (url, _) = try makeFile()
        let session = try DocumentStore().open(url)
        defer { session.close() }

        try FileManager.default.removeItem(at: url)

        XCTAssertEqual(try session.checkExternalChange(), .missing)
    }

    // MARK: - Scope ownership across sessions

    func testTwoSessionsEachOwnTheirOwnScope() throws {
        let (firstURL, _) = try makeFile("first.pdf")
        let (secondURL, _) = try makeFile("second.pdf")
        let spy = SecurityScopeSpy()
        let store = DocumentStore(access: spy)

        let first = try store.open(firstURL)
        let second = try store.open(secondURL)
        XCTAssertEqual(spy.starts, [firstURL, secondURL])

        first.close()
        XCTAssertEqual(spy.stops, [firstURL])

        second.close()
        XCTAssertEqual(spy.stops, [firstURL, secondURL])
    }

    // MARK: - Structures that cannot be written in place

    func testSymbolicLinkOpensButRefusesToSave() throws {
        let (target, payload) = try makeFile("target.pdf")
        let link = directory.url.appendingPathComponent("link.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let session = try DocumentStore().open(link)
        XCTAssertEqual(try session.read(), payload, "reading through a link is safe")

        let error = storeError(from: try session.save(TestPayload.bytes(64)))

        XCTAssertEqual(error, .unsupportedFileSituation(.symbolicLink, link))
        XCTAssertEqual(try Data(contentsOf: target), payload)
        let type = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeSymbolicLink, "the link must still be a link")
        session.close()
    }

    func testHardLinkRefusesToSaveAndKeepsBothNamesAttached() throws {
        let (first, payload) = try makeFile("first.pdf")
        let second = directory.url.appendingPathComponent("second.pdf")
        try FileManager.default.linkItem(at: first, to: second)

        let session = try DocumentStore().open(first)
        let error = storeError(from: try session.save(TestPayload.bytes(128)))

        XCTAssertEqual(error, .unsupportedFileSituation(.hardLink(linkCount: 2), first))
        XCTAssertEqual(try Data(contentsOf: first), payload)
        XCTAssertEqual(try Data(contentsOf: second), payload)
        XCTAssertEqual(inode(first), inode(second), "the two names must still share one inode")
        session.close()
    }
}
