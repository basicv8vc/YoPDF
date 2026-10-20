import XCTest
@testable import YoPDFCore

/// Failure injection through the one IO seam: every test here asserts the same
/// invariant from a different angle — a failed save leaves the original bytes
/// exactly as they were, and leaves nothing behind.
final class DocumentStoreFailureTests: XCTestCase {

    private var directory: TemporaryDirectory!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory("failure")
    }

    override func tearDown() {
        directory?.remove()
        directory = nil
        super.tearDown()
    }

    private func makeSession(
        failure: ScriptedDocumentStoreIO.Failure
    ) throws -> (URL, Data, DocumentSession, ScriptedDocumentStoreIO) {
        let payload = TestPayload.bytes(4096)
        let url = try directory.write("doc.pdf", payload)
        let io = ScriptedDocumentStoreIO()
        io.failAt = failure
        let session = try DocumentStore(io: io).open(url)
        return (url, payload, session, io)
    }

    func testStagingFailureLeavesOriginalIntactAndNoDebris() throws {
        let (url, payload, session, io) = try makeSession(failure: .staging)
        defer { session.close() }

        let error = storeError(from: try session.save(TestPayload.bytes(256, seed: 0x12)))

        XCTAssertEqual(error, .stagingFailed("injected staging failure"))
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertEqual(directory.stagingLeftovers(), [])
        XCTAssertEqual(io.replacementCount, 0, "nothing may reach the replacement step")
    }

    /// The staging file is written and validated, then the commit itself fails
    /// inside the coordinated write — the window where a careless
    /// implementation would already have damaged the original.
    func testReplacementFailureLeavesOriginalIntactAndRemovesStaging() throws {
        let (url, payload, session, io) = try makeSession(failure: .replacement)
        defer { session.close() }

        let error = storeError(from: try session.save(TestPayload.bytes(256, seed: 0x13)))

        XCTAssertEqual(error, .replacementFailed("injected replacement failure"))
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertEqual(directory.stagingLeftovers(), [], "a failed commit must clean its staging file")
        XCTAssertEqual(io.replacementCount, 0)
    }

    func testCoordinationFailureLeavesOriginalIntact() throws {
        let (url, payload, session, _) = try makeSession(failure: .coordination)
        defer { session.close() }

        let error = storeError(from: try session.save(TestPayload.bytes(256, seed: 0x14)))

        XCTAssertEqual(error, .coordinationFailed("injected coordination failure"))
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertEqual(directory.stagingLeftovers(), [])
    }

    /// A failed save must leave the session in a state where a later attempt
    /// still works, and must not advance the baseline.
    func testSessionStaysUsableAfterAFailedSave() throws {
        let (url, payload, session, io) = try makeSession(failure: .replacement)
        defer { session.close() }
        let openedVersion = session.version

        XCTAssertNotNil(storeError(from: try session.save(TestPayload.bytes(64))))

        io.failAt = nil
        let updated = TestPayload.bytes(512, seed: 0x15)
        try session.save(updated)

        XCTAssertEqual(try Data(contentsOf: url), updated)
        XCTAssertNotEqual(session.version, openedVersion)
        XCTAssertEqual(session.version.contentHash, TestPayload.sha256(updated))
        XCTAssertEqual(directory.stagingLeftovers(), [])
        XCTAssertNotEqual(try Data(contentsOf: url), payload)
    }

    func testConflictLeavesTheBaselineAndTheFileUntouched() throws {
        let payload = TestPayload.bytes(2048, seed: 0x21)
        let url = try directory.write("doc.pdf", payload)
        let session = try DocumentStore().open(url)
        defer { session.close() }
        let openedVersion = session.version

        let external = TestPayload.bytes(2048, seed: 0x22)
        try external.write(to: url)

        XCTAssertNotNil(storeError(from: try session.save(TestPayload.bytes(10))))

        XCTAssertEqual(try Data(contentsOf: url), external)
        XCTAssertEqual(session.version, openedVersion)
        guard case .modified = try session.checkExternalChange() else {
            return XCTFail("the session must still report the external change")
        }
    }
}
