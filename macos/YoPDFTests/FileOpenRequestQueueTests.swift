import XCTest

@MainActor
final class FileOpenRequestQueueTests: XCTestCase {

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
