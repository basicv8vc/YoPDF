import XCTest
@testable import YoPDFCore

/// A replacement can fail after the original has already been moved, and a
/// successful replacement can be followed by a failed version read. Both must
/// be reported as what they are, and neither may destroy the only surviving
/// copy of anything.
final class DocumentStoreRecoveryTests: XCTestCase {

    private var directory: TemporaryDirectory!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory("recovery")
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

    // MARK: - Partial commit: the original was moved aside

    func testPartialCommitWithMovedOriginalKeepsRecoveryCopyAndReportsUncertainty() throws {
        let (url, payload) = try makeFile()
        let io = ScriptedDocumentStoreIO()
        let session = try DocumentStore(io: io).open(url)
        defer { session.close() }
        let backup = directory.url.appendingPathComponent("recovered-original.pdf")
        io.partialCommit = .originalMovedTo(backup)

        let error = storeError(from: try session.save(TestPayload.bytes(300, seed: 0x31)))

        guard case let .replacementStateUncertain(recovery) = error else {
            return XCTFail("expected .replacementStateUncertain, got \(String(describing: error))")
        }
        XCTAssertEqual(recovery.originalLocation, backup, "the reported recovery location must be surfaced")
        let staging = try XCTUnwrap(recovery.stagingURL)
        XCTAssertEqual(recovery.recoverableURLs.count, 2)

        XCTAssertEqual(try Data(contentsOf: backup), payload, "the original must still be recoverable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: staging.path),
            "the new content is the only copy of that edit and must not be deleted"
        )

        XCTAssertEqual(session.state, .needsRefresh)
        XCTAssertEqual(storeError(from: try session.read()), .sessionNeedsRefresh)
        XCTAssertEqual(storeError(from: try session.save(TestPayload.bytes(8))), .sessionNeedsRefresh)
    }

    /// A session left in an unclear state can be resolved without reopening,
    /// but only when the file is actually readable again.
    func testRefreshAfterPartialCommitReportsTheTruthAboutTheTarget() throws {
        let (url, _) = try makeFile()
        let io = ScriptedDocumentStoreIO()
        let session = try DocumentStore(io: io).open(url)
        defer { session.close() }
        io.partialCommit = .originalMovedTo(directory.url.appendingPathComponent("backup.pdf"))

        XCTAssertNotNil(storeError(from: try session.save(TestPayload.bytes(64))))

        // The original was moved away, so refreshing cannot invent a baseline.
        let refreshError = storeError(from: try session.refresh())
        XCTAssertEqual(refreshError, .fileMissing(url))
        XCTAssertEqual(session.state, .needsRefresh)
    }

    // MARK: - Partial commit: the bytes landed but the call reported an error

    func testPartialCommitThatInstalledNewContentIsReportedAsCommitted() throws {
        let (url, _) = try makeFile()
        let io = ScriptedDocumentStoreIO()
        let session = try DocumentStore(io: io).open(url)
        defer { session.close() }
        io.partialCommit = .newContentInstalled
        let updated = TestPayload.bytes(400, seed: 0x41)

        // Must not throw: the content is on disk and verified by hash.
        try session.save(updated)

        XCTAssertEqual(try Data(contentsOf: url), updated)
        XCTAssertEqual(session.version.contentHash, TestPayload.sha256(updated))
        XCTAssertEqual(session.state, .open)
        XCTAssertEqual(directory.stagingLeftovers(), [])
    }

    // MARK: - Ambiguous failure with the original verifiably in place

    func testAmbiguousFailureWithOriginalStillInPlaceIsAPlainFailure() throws {
        let (url, payload) = try makeFile()
        let io = ScriptedDocumentStoreIO()
        let session = try DocumentStore(io: io).open(url)
        defer { session.close() }
        io.partialCommit = .nothingChanged

        let error = storeError(from: try session.save(TestPayload.bytes(64)))

        XCTAssertEqual(error, .replacementFailed("injected ambiguous failure"))
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertEqual(directory.stagingLeftovers(), [], "the original is intact, so staging is disposable")
        XCTAssertEqual(session.state, .open)
    }

    // MARK: - Post-commit failure

    func testPostCommitVersionFailureIsReportedAsCommittedAndRecoversByRefresh() throws {
        let (url, payload) = try makeFile()
        let io = ScriptedDocumentStoreIO()
        let session = try DocumentStore(io: io).open(url)
        defer { session.close() }
        io.failVersionAfterCommit = true
        let updated = TestPayload.bytes(512, seed: 0x51)

        let error = storeError(from: try session.save(updated))

        guard case let .committedButUnverified(reportedURL, _) = error else {
            return XCTFail("expected .committedButUnverified, got \(String(describing: error))")
        }
        XCTAssertEqual(reportedURL, url)
        XCTAssertEqual(try Data(contentsOf: url), updated, "the file really was written")
        XCTAssertNotEqual(try Data(contentsOf: url), payload)
        XCTAssertEqual(session.state, .needsRefresh, "the session must not pretend its baseline is current")
        XCTAssertEqual(storeError(from: try session.read()), .sessionNeedsRefresh)

        io.failVersionAfterCommit = false
        let refreshed = try session.refresh()

        XCTAssertEqual(refreshed.contentHash, TestPayload.sha256(updated))
        XCTAssertEqual(session.state, .open)
        XCTAssertEqual(try session.read(), updated)
        XCTAssertEqual(try session.checkExternalChange(), .unchanged)
    }

    func testSaveAfterPostCommitFailureIsBlockedUntilRefreshed() throws {
        let (url, _) = try makeFile()
        let io = ScriptedDocumentStoreIO()
        let session = try DocumentStore(io: io).open(url)
        defer { session.close() }
        io.failVersionAfterCommit = true

        XCTAssertNotNil(storeError(from: try session.save(TestPayload.bytes(128))))

        io.failVersionAfterCommit = false
        // A second save on a stale baseline could overwrite something it never
        // verified, so it must be refused until the session is refreshed.
        XCTAssertEqual(storeError(from: try session.save(TestPayload.bytes(256))), .sessionNeedsRefresh)

        try session.refresh()
        try session.save(TestPayload.bytes(256))
        XCTAssertEqual(try Data(contentsOf: url), TestPayload.bytes(256))
    }
}
