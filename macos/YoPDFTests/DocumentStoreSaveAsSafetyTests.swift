import XCTest
@testable import YoPDFCore

/// Save As has different overwrite rules from Save: the user chose a
/// destination, but that choice does not authorise replacing whatever happens
/// to be there by the time the bytes are committed.
final class DocumentStoreSaveAsSafetyTests: XCTestCase {

    private var directory: TemporaryDirectory!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory("saveas")
    }

    override func tearDown() {
        directory?.remove()
        directory = nil
        super.tearDown()
    }

    private func makeSession() throws -> (URL, DocumentSession, ScriptedDocumentStoreIO) {
        let url = try directory.write("doc.pdf", TestPayload.bytes(4096))
        let io = ScriptedDocumentStoreIO()
        let session = try DocumentStore(io: io).open(url)
        return (url, session, io)
    }

    func testRefusesWhenTargetChangedAfterTheUserConfirmed() throws {
        let (_, session, io) = try makeSession()
        defer { session.close() }
        let destination = try directory.write("existing.pdf", TestPayload.bytes(128, seed: 0x11))
        let external = TestPayload.bytes(128, seed: 0x22)
        io.beforeCoordinatedWrite = { try? external.write(to: destination) }

        let error = storeError(
            from: try session.saveAs(TestPayload.bytes(64, seed: 0x33), to: destination, overwrite: true)
        )

        guard case let .externalModificationDetected(change) = error, case .modified = change else {
            return XCTFail("expected .externalModificationDetected(.modified), got \(String(describing: error))")
        }
        XCTAssertEqual(try Data(contentsOf: destination), external, "the other app's bytes must survive")
        XCTAssertEqual(directory.stagingLeftovers(), [])
    }

    func testRefusesWhenTargetAppearedAfterTheUserConfirmed() throws {
        let (_, session, io) = try makeSession()
        defer { session.close() }
        let destination = directory.url.appendingPathComponent("appeared.pdf")
        let intruder = TestPayload.bytes(77, seed: 0x44)
        io.beforeCoordinatedWrite = { try? intruder.write(to: destination) }

        let error = storeError(from: try session.saveAs(TestPayload.bytes(64), to: destination))

        XCTAssertEqual(error, .targetAppearedDuringSave(destination))
        XCTAssertEqual(try Data(contentsOf: destination), intruder)
        XCTAssertEqual(directory.stagingLeftovers(), [])
    }

    func testRefusesWhenTargetWasDeletedAfterTheUserConfirmed() throws {
        let (_, session, io) = try makeSession()
        defer { session.close() }
        let destination = try directory.write("existing.pdf", TestPayload.bytes(128, seed: 0x11))
        io.beforeCoordinatedWrite = { try? FileManager.default.removeItem(at: destination) }

        let error = storeError(
            from: try session.saveAs(TestPayload.bytes(64), to: destination, overwrite: true)
        )

        XCTAssertEqual(error, .fileMissing(destination))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "a file the user deleted must not be recreated by Save As"
        )
    }

    // MARK: - Path aliases

    func testRefusesSymlinkAliasOfTheOpenFile() throws {
        let (url, session, _) = try makeSession()
        defer { session.close() }
        let alias = directory.url.appendingPathComponent("alias.pdf")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)

        let error = storeError(from: try session.saveAs(TestPayload.bytes(8), to: alias, overwrite: true))

        XCTAssertEqual(error, .unsupportedFileSituation(.sameFileAsCurrent, alias))
        XCTAssertEqual(try Data(contentsOf: url), TestPayload.bytes(4096))
    }

    func testRefusesAliasThroughSymlinkedParentDirectory() throws {
        let (url, session, _) = try makeSession()
        defer { session.close() }
        let linkedDirectory = directory.url.appendingPathComponent("linked-dir", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: directory.url)
        let destination = linkedDirectory.appendingPathComponent("doc.pdf")

        let error = storeError(
            from: try session.saveAs(TestPayload.bytes(8), to: destination, overwrite: true)
        )

        XCTAssertEqual(error, .unsupportedFileSituation(.sameFileAsCurrent, destination))
        XCTAssertEqual(try Data(contentsOf: url), TestPayload.bytes(4096))
    }

    func testRefusesHardLinkAliasOfTheOpenFile() throws {
        let (url, session, _) = try makeSession()
        defer { session.close() }
        let alias = directory.url.appendingPathComponent("hard-alias.pdf")
        try FileManager.default.linkItem(at: url, to: alias)

        let error = storeError(from: try session.saveAs(TestPayload.bytes(8), to: alias, overwrite: true))

        XCTAssertEqual(error, .unsupportedFileSituation(.sameFileAsCurrent, alias))
        XCTAssertEqual(try Data(contentsOf: url), TestPayload.bytes(4096))
        XCTAssertEqual(try Data(contentsOf: alias), TestPayload.bytes(4096))
    }

    // MARK: - Post-commit failure on the destination

    func testPostCommitVersionFailureLeavesTheCreatedFileAndNoSession() throws {
        let (url, session, io) = try makeSession()
        defer { session.close() }
        let destination = directory.url.appendingPathComponent("copy.pdf")
        let contents = TestPayload.bytes(321, seed: 0x55)
        io.failVersionAfterCommit = true

        let error = storeError(from: try session.saveAs(contents, to: destination))

        guard case let .committedButUnverified(reportedURL, _) = error else {
            return XCTFail("expected .committedButUnverified, got \(String(describing: error))")
        }
        XCTAssertEqual(reportedURL, destination)
        XCTAssertEqual(try Data(contentsOf: destination), contents, "the copy was written")
        XCTAssertEqual(try Data(contentsOf: url), TestPayload.bytes(4096), "the original is untouched")
        XCTAssertEqual(directory.stagingLeftovers(), [])
    }

    func testPostCommitVersionFailureReleasesTheDestinationsScope() throws {
        let spy = SecurityScopeSpy()
        let url = try directory.write("doc.pdf", TestPayload.bytes(1024))
        let io = ScriptedDocumentStoreIO()
        let session = try DocumentStore(access: spy, io: io).open(url)
        defer { session.close() }
        let destination = directory.url.appendingPathComponent("copy.pdf")
        io.failVersionAfterCommit = true

        XCTAssertNotNil(storeError(from: try session.saveAs(TestPayload.bytes(64), to: destination)))

        XCTAssertEqual(spy.starts, [url, destination])
        XCTAssertEqual(spy.stops, [destination], "no session was returned, so its lease must not leak")
    }
}
