import XCTest
@testable import YoPDFCore

final class WorkspaceStateTests: XCTestCase {

    func testCreatesSelectsAndClosesTabsWithoutDanglingActiveIdentity() throws {
        let first = WorkspaceTabIdentity()
        let second = WorkspaceTabIdentity()
        var state = WorkspaceState(initialTab: first)

        XCTAssertEqual(state.activeTabID, first.id)
        XCTAssertEqual(state.activePaneID, first.paneID)
        XCTAssertTrue(state.insert(second))
        XCTAssertEqual(state.activeTabID, second.id)
        XCTAssertEqual(state.activePaneID, second.paneID)

        XCTAssertTrue(state.activate(tabID: first.id))
        XCTAssertEqual(state.close(tabID: first.id), first)
        XCTAssertEqual(state.tabs, [second])
        XCTAssertEqual(state.activeTabID, second.id)
        XCTAssertEqual(state.activePaneID, second.paneID)
        XCTAssertFalse(state.contains(tabID: first.id))
    }

    func testClosingInactiveTabLeavesActiveTabAloneAndLastTabCannotBeRemoved() {
        let first = WorkspaceTabIdentity()
        let second = WorkspaceTabIdentity()
        var state = WorkspaceState(initialTab: first)
        XCTAssertTrue(state.insert(second))

        XCTAssertEqual(state.close(tabID: first.id), first)
        XCTAssertEqual(state.activeTabID, second.id)
        XCTAssertNil(state.close(tabID: second.id))
        XCTAssertEqual(state.tabs, [second])
        XCTAssertEqual(state.activeTabID, second.id)
    }

    func testRejectsDuplicateTabOrPaneIDsAndUnknownActivation() {
        let first = WorkspaceTabIdentity()
        var state = WorkspaceState(initialTab: first)

        XCTAssertFalse(state.insert(WorkspaceTabIdentity(id: first.id)))
        XCTAssertFalse(state.insert(WorkspaceTabIdentity(paneID: first.paneID)))
        XCTAssertFalse(state.activate(tabID: UUID()))
        XCTAssertEqual(state.tabs, [first])
        XCTAssertEqual(state.activeTabID, first.id)
    }

    func testAdjacentTabActivationWrapsAtBothEnds() {
        let first = WorkspaceTabIdentity()
        let second = WorkspaceTabIdentity()
        let third = WorkspaceTabIdentity()
        var state = WorkspaceState(initialTab: first)
        XCTAssertTrue(state.insert(second, activate: false))
        XCTAssertTrue(state.insert(third, activate: false))
        XCTAssertEqual(state.activeTabID, first.id)

        // ⇧⌘[ from the leftmost tab selects the rightmost one, and repeating
        // the shortcut keeps walking left through the ring.
        for expected in [third.id, second.id, first.id, third.id] {
            XCTAssertEqual(state.activateAdjacentTab(direction: .previous), expected)
            XCTAssertEqual(state.activeTabID, expected)
        }

        // ⇧⌘] from the rightmost tab selects the leftmost one.
        for expected in [first.id, second.id, third.id, first.id] {
            XCTAssertEqual(state.activateAdjacentTab(direction: .next), expected)
            XCTAssertEqual(state.activeTabID, expected)
        }

        XCTAssertEqual(state.tabs, [first, second, third], "Navigation must not reorder tabs.")
        XCTAssertEqual(state.activePaneID, first.paneID)
    }

    func testAdjacentTabActivationWithSingleTabIsANoOp() {
        let only = WorkspaceTabIdentity()
        var state = WorkspaceState(initialTab: only)

        XCTAssertEqual(state.activateAdjacentTab(direction: .previous), only.id)
        XCTAssertEqual(state.activateAdjacentTab(direction: .next), only.id)
        XCTAssertEqual(state.activeTabID, only.id)
        XCTAssertEqual(state.tabs, [only])
    }

    func testAdjacentTabActivationUsesPostCloseOrdering() {
        let first = WorkspaceTabIdentity()
        let second = WorkspaceTabIdentity()
        let third = WorkspaceTabIdentity()
        var state = WorkspaceState(initialTab: first)
        XCTAssertTrue(state.insert(second))
        XCTAssertTrue(state.insert(third))

        XCTAssertEqual(state.close(tabID: second.id), second)
        XCTAssertEqual(state.activeTabID, third.id)
        XCTAssertEqual(state.activateAdjacentTab(direction: .next), first.id)
        XCTAssertEqual(state.activateAdjacentTab(direction: .previous), third.id)
    }
}
