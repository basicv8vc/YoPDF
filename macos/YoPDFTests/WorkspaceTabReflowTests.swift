import XCTest
@testable import YoPDFCore

final class WorkspaceTabReflowTests: XCTestCase {
    private let first = UUID()
    private let second = UUID()
    private let third = UUID()

    /// Three deliberately unequal widths: A 100, B 120, C 110, spaced by 4.
    private var ids: [UUID] { [first, second, third] }
    private var slots: [UUID: WorkspaceTabReflow.Slot] {
        [
            first: .init(minX: 0, width: 100),
            second: .init(minX: 104, width: 120),
            third: .init(minX: 228, width: 110),
        ]
    }
    private let spacing = 4.0

    private func offsets(
        dragging tabID: UUID,
        insertionIndex: Int,
        tabIDs: [UUID]? = nil,
        measurements: [UUID: WorkspaceTabReflow.Slot]? = nil
    ) -> [UUID: Double] {
        WorkspaceTabReflow.offsets(
            tabIDs: tabIDs ?? ids,
            slots: measurements ?? slots,
            spacing: spacing,
            draggingTabID: tabID,
            insertionIndex: insertionIndex
        )
    }

    private func assertOffset(
        _ actual: Double?,
        equals expected: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNotNil(actual, file: file, line: line)
        guard let actual else { return }
        XCTAssertEqual(actual, expected, accuracy: 0.001, file: file, line: line)
    }

    // MARK: - Live reflow offsets

    func testDraggingToFrontSlidesEveryOtherTabRight() {
        let result = offsets(dragging: third, insertionIndex: 0)

        // The third tab is 110 wide, so both earlier tabs shift by 110 + 4.
        assertOffset(result[first], equals: 114)
        assertOffset(result[second], equals: 114)
        XCTAssertNil(result[third], "The lifted tab follows the pointer, not a slot offset.")
        XCTAssertEqual(result.count, 2)
    }

    func testDraggingToEndSlidesTheTrailingTabLeft() {
        let result = offsets(dragging: second, insertionIndex: 2)

        assertOffset(result[first], equals: 0)
        assertOffset(result[third], equals: -124)
        XCTAssertNil(result[second])
        XCTAssertEqual(result.count, 2)
    }

    func testOwnSlotProducesNoReflow() {
        let result = offsets(dragging: second, insertionIndex: 1)

        assertOffset(result[first], equals: 0)
        assertOffset(result[third], equals: 0)
        XCTAssertNil(result[second])
    }

    /// Geometry precondition for a cancelled drag. Cancellation itself is
    /// handled in the SwiftUI layer (a `@GestureState` flag flipping to
    /// `false` clears the visual drag state without calling `moveTab`, so the
    /// committed order is untouched by construction). What this test pins down
    /// is the pure-geometry half: when the insertion index returns to the
    /// dragged tab's own slot, every stationary tab's offset unwinds to zero —
    /// so restoring the visuals requires nothing beyond dropping the snapshot.
    /// The gesture-lifecycle behavior itself needs UI-level verification.
    func testAbandonedDragSnapshotUnwindsToTheOriginalLayout() {
        // Mid-drag the strip could be showing any in-flight order...
        let inFlight = offsets(dragging: second, insertionIndex: 2)
        assertOffset(inFlight[third], equals: -124)

        // ...cancelling returns the tab to its own slot, and every offset
        // unwinds to zero.
        let restore = offsets(dragging: second, insertionIndex: 1)
        assertOffset(restore[first], equals: 0)
        assertOffset(restore[third], equals: 0)
        XCTAssertNil(restore[second])
    }

    func testOffsetsClampInsertionIndexToTheStrip() {
        let pastEnd = offsets(dragging: second, insertionIndex: 99)
        assertOffset(pastEnd[third], equals: -124)

        let beforeStart = offsets(dragging: second, insertionIndex: -5)
        // B lands first, so A shifts by B's width (120 + 4) and C stays put.
        assertOffset(beforeStart[first], equals: 124)
        assertOffset(beforeStart[third], equals: 0)
    }

    func testUnequalWidthsUseAccumulatedLayoutInsteadOfOneStride() {
        // A, C, B: C takes the slot right after A (104), B lands after C at
        // 218. B shifts by C's width (110 + 4), not by a uniform stride.
        let result = offsets(dragging: third, insertionIndex: 1)

        assertOffset(result[first], equals: 0)
        assertOffset(result[second], equals: 114)
        XCTAssertNil(result[third], "The lifted tab has no slot offset.")
        XCTAssertEqual(result.count, 2)
    }

    func testIncompleteMeasurementLeavesTabsInPlace() {
        var partial = slots
        partial.removeValue(forKey: third)

        XCTAssertTrue(offsets(dragging: second, insertionIndex: 2, measurements: partial).isEmpty)
    }

    func testUnknownDraggedTabLeavesTabsInPlace() {
        XCTAssertTrue(offsets(dragging: UUID(), insertionIndex: 1).isEmpty)
    }

    func testSingleTabHasNoReflow() {
        let only = first
        let result = WorkspaceTabReflow.offsets(
            tabIDs: [only],
            slots: [only: .init(minX: 0, width: 100)],
            spacing: spacing,
            draggingTabID: only,
            insertionIndex: 0
        )

        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Insertion index

    func testInsertionIndexCountsOnlyOtherTabMidpoints() {
        // Midpoints: A 50, B 164, C 283. B is being dragged.
        let index = { (x: Double) in
            WorkspaceTabReflow.insertionIndex(
                pointerX: x,
                tabIDs: self.ids,
                slots: self.slots,
                draggingTabID: self.second
            )
        }

        XCTAssertEqual(index(50), 0)
        XCTAssertEqual(index(200), 1)
        XCTAssertEqual(index(400), 2)
    }

    func testInsertionIndexIgnoresTheDraggedTab() {
        let index = WorkspaceTabReflow.insertionIndex(
            pointerX: 100,
            tabIDs: ids,
            slots: slots,
            draggingTabID: first
        )

        // A's own midpoint (50) must not count; B and C are still ahead.
        XCTAssertEqual(index, 0)
    }

    func testInsertionIndexSkipsUnmeasuredTabs() {
        var partial = slots
        partial.removeValue(forKey: third)

        let index = WorkspaceTabReflow.insertionIndex(
            pointerX: 400,
            tabIDs: ids,
            slots: partial,
            draggingTabID: second
        )

        XCTAssertEqual(index, 1)
    }
}
