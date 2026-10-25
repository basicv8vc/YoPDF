import XCTest

@MainActor
final class FileOpenRequestQueueTests: XCTestCase {

    func testPrefersKeyReaderThenMainReaderThenFrontmostReader() {
        let readers = ["front", "back"]
        XCTAssertEqual(FileOpenRequestQueue.preferredReader(
            key: "back", main: "front", orderedReaders: readers
        ), "back")
        XCTAssertEqual(FileOpenRequestQueue.preferredReader(
            key: nil, main: "back", orderedReaders: readers
        ), "back")
        XCTAssertEqual(FileOpenRequestQueue.preferredReader(
            key: nil, main: nil, orderedReaders: readers
        ), "front", "A recreated window must receive the file even before it becomes key.")
    }

    func testIgnoresPanelsAndClosedReadersWhenChoosingARecipient() {
        XCTAssertEqual(FileOpenRequestQueue.preferredReader(
            key: "panel", main: "closed", orderedReaders: ["reader"]
        ), "reader")
        XCTAssertNil(FileOpenRequestQueue.preferredReader(
            key: "closed", main: "closed", orderedReaders: [String]()
        ), "An event must wait for a reader that is actually available.")
    }

    func testRejectsAdditionalFinderEventsUntilTheCurrentRequestFinishes() throws {
        let queue = FileOpenRequestQueue()
        let first = URL(fileURLWithPath: "/tmp/first.pdf")
        let second = URL(fileURLWithPath: "/tmp/second.pdf")
        let readerID = UUID()

        XCTAssertTrue(queue.enqueue(first))
        XCTAssertFalse(queue.enqueue(second), "A second event must not be left behind the first.")
        let request = try XCTUnwrap(queue.takeNext(readerID: readerID))
        XCTAssertEqual(request.url, first)
        XCTAssertNil(queue.takeNext(readerID: readerID), "A request can only be delivered once.")

        // Taking the URL does not release the slot: the reader may still be
        // waiting for the user to answer its unsaved-work prompt.
        XCTAssertFalse(queue.enqueue(second))

        XCTAssertTrue(queue.finishRequest(requestID: request.id, readerID: readerID))
        XCTAssertNil(queue.takeNext(readerID: readerID), "Finishing the request must leave no stale URL.")
        XCTAssertTrue(queue.enqueue(second))
        let secondRequest = try XCTUnwrap(queue.takeNext(readerID: readerID))
        XCTAssertEqual(secondRequest.url, second)
        XCTAssertTrue(queue.finishRequest(requestID: secondRequest.id, readerID: readerID))
    }

    func testUnrelatedReaderCloseDoesNotReassignAnotherReadersRequest() throws {
        let queue = FileOpenRequestQueue()
        let first = URL(fileURLWithPath: "/tmp/first.pdf")
        let readerA = UUID()
        let readerB = UUID()
        let readerC = UUID()

        XCTAssertTrue(queue.enqueue(first))
        let requestA = try XCTUnwrap(queue.takeNext(readerID: readerA))

        XCTAssertFalse(queue.readerWindowDidClose(readerID: readerB))
        XCTAssertNil(queue.takeNext(readerID: readerC), "Reader C must not see reader A's in-flight request.")
        XCTAssertFalse(queue.finishRequest(requestID: requestA.id, readerID: readerB))
        XCTAssertTrue(queue.finishRequest(requestID: requestA.id, readerID: readerA))
        XCTAssertFalse(queue.readerWindowDidClose(readerID: readerA), "A finished request needs no recovery.")
    }

    func testOwningReaderCloseRequeuesRequestAndRejectsItsStaleCompletion() throws {
        let queue = FileOpenRequestQueue()
        let first = URL(fileURLWithPath: "/tmp/first.pdf")
        let readerA = UUID()
        let readerC = UUID()

        XCTAssertTrue(queue.enqueue(first))
        let requestA = try XCTUnwrap(queue.takeNext(readerID: readerA))
        XCTAssertTrue(queue.readerWindowDidClose(readerID: readerA))

        let requestC = try XCTUnwrap(queue.takeNext(readerID: readerC))
        XCTAssertEqual(requestC.id, requestA.id, "A handoff keeps the same logical request identity.")
        XCTAssertEqual(requestC.url, first, "The next reader must receive the in-flight URL.")
        XCTAssertFalse(queue.readerWindowDidClose(readerID: readerA))
        XCTAssertFalse(queue.finishRequest(requestID: requestA.id, readerID: readerA))
        XCTAssertTrue(queue.finishRequest(requestID: requestC.id, readerID: readerC))
        XCTAssertNil(queue.takeNext(readerID: readerC))
    }

    func testClosingReaderWakesQueueWhenRequestIsStillUnclaimed() throws {
        let queue = FileOpenRequestQueue()
        let first = URL(fileURLWithPath: "/tmp/first.pdf")
        let readerB = UUID()
        let readerC = UUID()

        XCTAssertTrue(queue.enqueue(first))
        XCTAssertTrue(queue.readerWindowDidClose(readerID: readerB))
        let requestC = try XCTUnwrap(queue.takeNext(readerID: readerC))
        XCTAssertEqual(requestC.url, first)
        XCTAssertTrue(queue.finishRequest(requestID: requestC.id, readerID: readerC))
    }
}
