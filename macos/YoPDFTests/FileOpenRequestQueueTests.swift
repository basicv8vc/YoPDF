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

    func testRejectsAdditionalFinderEventsUntilTheCurrentRequestFinishes() {
        let queue = FileOpenRequestQueue()
        let first = URL(fileURLWithPath: "/tmp/first.pdf")
        let second = URL(fileURLWithPath: "/tmp/second.pdf")

        XCTAssertTrue(queue.enqueue(first))
        XCTAssertFalse(queue.enqueue(second), "A second event must not be left behind the first.")
        XCTAssertEqual(queue.takeNext(), first)
        XCTAssertNil(queue.takeNext(), "A request can only be delivered once.")

        // Taking the URL does not release the slot: the reader may still be
        // waiting for the user to answer its unsaved-work prompt.
        XCTAssertFalse(queue.enqueue(second))

        queue.finishRequest()
        XCTAssertNil(queue.takeNext(), "Finishing the request must leave no stale URL.")
        XCTAssertTrue(queue.enqueue(second))
        XCTAssertEqual(queue.takeNext(), second)
        queue.finishRequest()
    }
}
