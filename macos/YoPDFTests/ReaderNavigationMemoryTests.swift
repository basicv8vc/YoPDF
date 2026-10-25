import XCTest
@testable import YoPDFCore

final class ReaderNavigationMemoryTests: XCTestCase {

    func testOutlineSelectionAndNestedExpansionSurviveSidebarRecreation() {
        var memory = ReaderNavigationMemory()
        XCTAssertTrue(memory.prepare(for: 1))

        memory.selectOutlineItem("0.1")
        memory.setOutlineItem("0", expanded: false)
        memory.setOutlineItem("0.1", expanded: false)

        // Recreating the sidebar for the same document must keep the overrides.
        XCTAssertFalse(memory.prepare(for: 1))
        XCTAssertEqual(memory.selectedOutlineItemID, "0.1")
        XCTAssertFalse(memory.isExpanded(for: "0", defaultValue: true))
        XCTAssertFalse(memory.isExpanded(for: "0.1", defaultValue: true))
    }

    func testDocumentChangeClearsOutlineAndAnnotationMemory() {
        var memory = ReaderNavigationMemory()
        memory.prepare(for: 1)
        memory.selectOutlineItem("0.1")
        memory.setOutlineItem("0.1", expanded: false)
        memory.markOutlineLoaded()
        memory.markAnnotationIndexUpdated(revision: 7)

        XCTAssertTrue(memory.prepare(for: 2))

        XCTAssertNil(memory.selectedOutlineItemID)
        XCTAssertTrue(memory.outlineExpansionOverrides.isEmpty)
        XCTAssertTrue(memory.needsOutlineLoad)
        XCTAssertTrue(memory.needsAnnotationIndex(for: 7))
    }

    func testAnnotationIndexRevisionIsTrackedOnlyAfterIndexing() {
        var memory = ReaderNavigationMemory()
        memory.prepare(for: 4)

        XCTAssertTrue(memory.needsAnnotationIndex(for: 0))
        XCTAssertFalse(memory.hasAnnotationIndex)

        memory.markAnnotationIndexUpdated(revision: 0)
        XCTAssertFalse(memory.needsAnnotationIndex(for: 0))
        XCTAssertTrue(memory.needsAnnotationIndex(for: 1))
    }
}
