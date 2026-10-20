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

    // MARK: - A coordinator error must not hide a write that already happened

    func testCoordinatedWritePrefersAccessorSuccessOverACoordinationError() {
        let committed = URL(fileURLWithPath: "/tmp/yopdf-committed.pdf")
        let result = SystemDocumentStoreIO.resolve(
            outcome: .success(committed),
            coordinationError: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
        )

        guard case let .success(resolved) = result else {
            return XCTFail("a completed write block must win over a coordination error")
        }
        XCTAssertEqual(resolved, committed)
    }

    func testCoordinatedWriteKeepsTheAccessorErrorWhenBothFail() {
        let failure = DocumentStoreError.externalModificationDetected(.missing)
        let result = SystemDocumentStoreIO.resolve(
            outcome: .failure(failure),
            coordinationError: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
        )

        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(
                error as? DocumentStoreError,
                failure,
                "the specific outcome must not be replaced by a generic coordination failure"
            )
        }
    }

    func testCoordinatedWriteReportsCoordinationFailureOnlyWhenTheBlockNeverRan() {
        let coordinationError = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteUnknownError,
            userInfo: [NSLocalizedDescriptionKey: "another process holds the file"]
        )

        let withError = SystemDocumentStoreIO.resolve(
            outcome: nil,
            coordinationError: coordinationError
        )
        XCTAssertThrowsError(try withError.get()) { error in
            guard case .coordinationFailed = (error as? DocumentStoreError) else {
                return XCTFail("expected .coordinationFailed, got \(error)")
            }
        }

        let withoutAnything = SystemDocumentStoreIO.resolve(outcome: nil, coordinationError: nil)
        XCTAssertThrowsError(try withoutAnything.get()) { error in
            guard case .coordinationFailed = (error as? DocumentStoreError) else {
                return XCTFail("expected .coordinationFailed, got \(error)")
            }
        }
    }

    func testCoordinatorErrorAfterTheWriteBlockRanIsNotReportedAsUncommitted() throws {
        let (url, payload) = try makeFile()
        let io = ScriptedDocumentStoreIO()
        let session = try DocumentStore(io: io).open(url)
        defer { session.close() }
        io.coordinationFailsAfterWrite = true
        let updated = TestPayload.bytes(700, seed: 0x71)

        // No error: the bytes are on disk, so the save committed even though
        // the coordinator complained afterwards.
        let version = try session.save(updated)

        XCTAssertEqual(try Data(contentsOf: url), updated)
        XCTAssertNotEqual(try Data(contentsOf: url), payload)
        XCTAssertEqual(version.contentHash, TestPayload.sha256(updated))
        XCTAssertEqual(session.state, .open)
        XCTAssertEqual(session.version.contentHash, TestPayload.sha256(updated))
        XCTAssertEqual(try session.checkExternalChange(), .unchanged)
        XCTAssertEqual(directory.stagingLeftovers(), [])
    }

    // MARK: - refresh() must not adopt a stranger

    func testRefreshAfterPartialCommitRefusesAStrangerFileAtThePath() throws {
        let (url, payload) = try makeFile()
        let io = ScriptedDocumentStoreIO()
        let session = try DocumentStore(io: io).open(url)
        defer { session.close() }
        io.partialCommit = .originalMovedTo(directory.url.appendingPathComponent("moved-original.pdf"))

        XCTAssertNotNil(storeError(from: try session.save(TestPayload.bytes(320, seed: 0x81))))
        XCTAssertEqual(session.state, .needsRefresh)

        // While the outcome is undecided, another program puts its own file at
        // the same path.
        let stranger = TestPayload.bytes(999, seed: 0x82)
        try stranger.write(to: url)

        let error = storeError(from: try session.refresh())

        guard case let .externalModificationDetected(change) = error, case .replaced = change else {
            return XCTFail("expected .externalModificationDetected(.replaced), got \(String(describing: error))")
        }
        XCTAssertEqual(session.state, .needsRefresh, "refresh must not turn an unknown file into a baseline")
        XCTAssertEqual(
            session.version.contentHash,
            TestPayload.sha256(payload),
            "the recorded baseline must not move"
        )

        // And the session stays unwritable, so the stranger survives.
        XCTAssertEqual(storeError(from: try session.save(TestPayload.bytes(64))), .sessionNeedsRefresh)
        XCTAssertEqual(try Data(contentsOf: url), stranger)
    }

    func testRefreshAcceptsTheOriginalWhenItIsPutBack() throws {
        let (url, payload) = try makeFile()
        let io = ScriptedDocumentStoreIO()
        let session = try DocumentStore(io: io).open(url)
        defer { session.close() }
        let backup = directory.url.appendingPathComponent("moved-original.pdf")
        io.partialCommit = .originalMovedTo(backup)

        XCTAssertNotNil(storeError(from: try session.save(TestPayload.bytes(320, seed: 0x83))))
        XCTAssertEqual(session.state, .needsRefresh)

        // The original comes back at its own path: same inode, same bytes.
        try FileManager.default.moveItem(at: backup, to: url)

        let restored = try session.refresh()

        XCTAssertEqual(restored.contentHash, TestPayload.sha256(payload))
        XCTAssertEqual(session.state, .open)
        XCTAssertEqual(try session.read(), payload)
        XCTAssertEqual(try session.checkExternalChange(), .unchanged)
    }

    // MARK: - refresh() is not a reload

    func testRefreshOnAnOpenSessionRefusesToRebaselineAnExternalChange() throws {
        let (url, payload) = try makeFile()
        let session = try DocumentStore().open(url)
        defer { session.close() }

        // Another program rewrites the file while it is open. `Data.write`
        // truncates in place, so the identity survives and only the bytes move.
        let external = TestPayload.bytes(2048, seed: 0x91)
        try external.write(to: url)

        // A session with no pending save has nothing to verify, and must not
        // adopt the other app's bytes as the baseline for the next save.
        XCTAssertEqual(storeError(from: try session.refresh()), .reloadRequired)
        XCTAssertEqual(session.state, .open)
        XCTAssertEqual(
            session.version.contentHash,
            TestPayload.sha256(payload),
            "the baseline must stay at the version the session opened"
        )

        // And the next save is still checked against that version, so the
        // external file is reported rather than overwritten.
        let error = storeError(from: try session.save(TestPayload.bytes(64)))
        guard case let .externalModificationDetected(change) = error, case .modified = change else {
            return XCTFail("expected .externalModificationDetected(.modified), got \(String(describing: error))")
        }
        XCTAssertEqual(try Data(contentsOf: url), external, "the other app's bytes must survive")
        XCTAssertEqual(session.state, .open)
    }
}
