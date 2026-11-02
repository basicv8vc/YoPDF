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
}
