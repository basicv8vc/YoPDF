import XCTest
@testable import YoPDFCore

/// The session's security scope must outlive every operation that is still
/// using it. These tests make the interleaving deterministic with semaphores
/// instead of sleeps.
final class DocumentStoreLifecycleTests: XCTestCase {

    private var directory: TemporaryDirectory!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory("lifecycle")
    }

    override func tearDown() {
        directory?.remove()
        directory = nil
        super.tearDown()
    }

    func testCloseWaitsForInFlightReadBeforeReleasingTheScope() throws {
        let url = try directory.write("doc.pdf", TestPayload.bytes(2048))
        let spy = SecurityScopeSpy()
        let io = BlockingReadIO()
        let session = try DocumentStore(access: spy, io: io).open(url)

        let readFinished = expectation(description: "read finished")
        DispatchQueue.global().async {
            _ = try? session.read()
            readFinished.fulfill()
        }
        XCTAssertEqual(
            io.readStarted.wait(timeout: .now() + 5),
            .success,
            "the read must be inside the filesystem call before close is attempted"
        )

        let closeFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            session.close()
            closeFinished.signal()
        }

        // While the read holds the scope, close must not complete.
        XCTAssertEqual(
            closeFinished.wait(timeout: .now() + 0.3),
            .timedOut,
            "close released the scope while a read was still using it"
        )
        XCTAssertEqual(spy.stops, [])

        io.allowReadToFinish.signal()
        wait(for: [readFinished], timeout: 5)
        XCTAssertEqual(closeFinished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(spy.stops, [url])
        XCTAssertEqual(io.events, ["readStarted", "readFinished"])
    }

    func testEveryOperationIsRejectedAfterClose() throws {
        let url = try directory.write("doc.pdf", TestPayload.bytes(512))
        let session = try DocumentStore().open(url)
        session.close()

        XCTAssertEqual(storeError(from: try session.read()), .sessionClosed)
        XCTAssertEqual(storeError(from: try session.checkExternalChange()), .sessionClosed)
        XCTAssertEqual(storeError(from: try session.save(TestPayload.bytes(8))), .sessionClosed)
        XCTAssertEqual(storeError(from: try session.saveAs(TestPayload.bytes(8), to: directory.url.appendingPathComponent("x.pdf"))), .sessionClosed)
        XCTAssertEqual(storeError(from: try session.refresh()), .sessionClosed)
        XCTAssertEqual(session.state, .closed)
    }

    func testConcurrentSavesOnOneSessionAreSerialised() throws {
        let url = try directory.write("doc.pdf", TestPayload.bytes(4096))
        let session = try DocumentStore().open(url)
        defer { session.close() }

        let first = TestPayload.bytes(1000, seed: 0x61)
        let second = TestPayload.bytes(2000, seed: 0x62)
        let group = DispatchGroup()
        let failures = FailureBox()

        for payload in [first, second] {
            DispatchQueue.global().async(group: group) {
                do { try session.save(payload) }
                catch { failures.record(String(describing: error)) }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)

        XCTAssertEqual(failures.values, [], "saves on one session must queue, not conflict with themselves")
        let final = try Data(contentsOf: url)
        XCTAssertTrue(final == first || final == second, "the file must hold one complete payload")
        XCTAssertEqual(session.version.contentHash, TestPayload.sha256(final))
    }
}

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func record(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}
