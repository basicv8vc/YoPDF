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

    // MARK: - Drag-to-reorder

    func testMoveReordersTabsWithoutChangingTheActiveTab() {
        let first = WorkspaceTabIdentity()
        let second = WorkspaceTabIdentity()
        let third = WorkspaceTabIdentity()
        var state = WorkspaceState(initialTab: first)
        XCTAssertTrue(state.insert(second, activate: false))
        XCTAssertTrue(state.insert(third, activate: false))
        XCTAssertTrue(state.activate(tabID: second.id))

        XCTAssertTrue(state.move(tabID: second.id, toInsertionIndex: 0))
        XCTAssertEqual(state.tabs, [second, first, third])
        XCTAssertEqual(state.activeTabID, second.id, "Moving a tab must not change which PDF is showing.")
        XCTAssertEqual(state.activePaneID, second.paneID)

        XCTAssertTrue(state.move(tabID: second.id, toInsertionIndex: 2))
        XCTAssertEqual(state.tabs, [first, third, second])
        XCTAssertEqual(state.activeTabID, second.id)
    }

    func testMoveToOwnSlotLeavesOrderingUntouched() {
        let first = WorkspaceTabIdentity()
        let second = WorkspaceTabIdentity()
        let third = WorkspaceTabIdentity()
        var state = WorkspaceState(initialTab: first)
        XCTAssertTrue(state.insert(second, activate: false))
        XCTAssertTrue(state.insert(third, activate: false))

        for index in 0..<3 {
            let tabID = state.tabs[index].id
            XCTAssertTrue(state.move(tabID: tabID, toInsertionIndex: index))
            XCTAssertEqual(state.tabs, [first, second, third])
        }
    }

    func testMoveClampsInsertionIndexToTheStrip() {
        let first = WorkspaceTabIdentity()
        let second = WorkspaceTabIdentity()
        let third = WorkspaceTabIdentity()
        var state = WorkspaceState(initialTab: first)
        XCTAssertTrue(state.insert(second, activate: false))
        XCTAssertTrue(state.insert(third, activate: false))

        // A drag that ends past either end of a scrolled strip still lands on
        // the first or last slot instead of being dropped.
        XCTAssertTrue(state.move(tabID: first.id, toInsertionIndex: 99))
        XCTAssertEqual(state.tabs, [second, third, first])

        XCTAssertTrue(state.move(tabID: first.id, toInsertionIndex: -5))
        XCTAssertEqual(state.tabs, [first, second, third])
    }

    func testMoveUnknownTabIsRejected() {
        let only = WorkspaceTabIdentity()
        var state = WorkspaceState(initialTab: only)

        XCTAssertFalse(state.move(tabID: UUID(), toInsertionIndex: 0))
        XCTAssertEqual(state.tabs, [only])
        XCTAssertEqual(state.activeTabID, only.id)
    }

    // MARK: - One-slot moves (keyboard / context menu)

    func testMoveByDirectionSlidesOneSlotAndKeepsTheActiveTab() {
        let first = WorkspaceTabIdentity()
        let second = WorkspaceTabIdentity()
        let third = WorkspaceTabIdentity()
        var state = WorkspaceState(initialTab: first)
        XCTAssertTrue(state.insert(second, activate: false))
        XCTAssertTrue(state.insert(third, activate: false))
        XCTAssertTrue(state.activate(tabID: second.id))

        XCTAssertTrue(state.move(tabID: second.id, direction: .previous))
        XCTAssertEqual(state.tabs, [second, first, third])
        XCTAssertEqual(state.activeTabID, second.id)

        XCTAssertTrue(state.move(tabID: second.id, direction: .next))
        XCTAssertEqual(state.tabs, [first, second, third])
        XCTAssertEqual(state.activeTabID, second.id)
        XCTAssertEqual(state.activePaneID, second.paneID)
    }

    func testMoveByDirectionWrapsAtBothEnds() {
        let first = WorkspaceTabIdentity()
        let second = WorkspaceTabIdentity()
        let third = WorkspaceTabIdentity()
        var state = WorkspaceState(initialTab: first)
        XCTAssertTrue(state.insert(second, activate: false))
        XCTAssertTrue(state.insert(third, activate: false))

        // The leftmost tab wraps to the last slot; moving the same tab right
        // from there wraps back to the first, so a held shortcut never stalls.
        XCTAssertTrue(state.move(tabID: first.id, direction: .previous))
        XCTAssertEqual(state.tabs, [second, third, first])
        XCTAssertTrue(state.move(tabID: first.id, direction: .next))
        XCTAssertEqual(state.tabs, [first, second, third])
    }

    func testMoveActiveTabFollowsTheSelection() {
        let first = WorkspaceTabIdentity()
        let second = WorkspaceTabIdentity()
        let third = WorkspaceTabIdentity()
        var state = WorkspaceState(initialTab: first)
        XCTAssertTrue(state.insert(second, activate: false))
        XCTAssertTrue(state.insert(third, activate: false))
        XCTAssertTrue(state.activate(tabID: second.id))

        XCTAssertTrue(state.moveActiveTab(direction: .previous))
        XCTAssertEqual(state.tabs, [second, first, third])
        XCTAssertEqual(state.activeTabID, second.id)

        XCTAssertTrue(state.activate(tabID: third.id))
        XCTAssertTrue(state.moveActiveTab(direction: .previous))
        XCTAssertEqual(state.tabs, [second, third, first])
        XCTAssertEqual(state.activeTabID, third.id)

        // second is now leftmost, so moving it left wraps to the end.
        XCTAssertTrue(state.activate(tabID: second.id))
        XCTAssertTrue(state.moveActiveTab(direction: .previous))
        XCTAssertEqual(state.tabs, [third, first, second])
        XCTAssertEqual(state.activeTabID, second.id)
    }

    func testMoveByDirectionRejectsSingleTabAndUnknownTab() {
        let only = WorkspaceTabIdentity()
        var state = WorkspaceState(initialTab: only)

        XCTAssertFalse(state.move(tabID: only.id, direction: .previous))
        XCTAssertFalse(state.move(tabID: only.id, direction: .next))
        XCTAssertFalse(state.moveActiveTab(direction: .previous))
        XCTAssertFalse(state.moveActiveTab(direction: .next))
        XCTAssertEqual(state.tabs, [only])
        XCTAssertEqual(state.activeTabID, only.id)

        XCTAssertTrue(state.insert(WorkspaceTabIdentity(), activate: false))
        XCTAssertFalse(state.move(tabID: UUID(), direction: .previous))
        XCTAssertFalse(state.move(tabID: UUID(), direction: .next))
        XCTAssertEqual(state.activeTabID, only.id)
    }
}
