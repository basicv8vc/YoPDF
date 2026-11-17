//
//  PaneDragDropUITests.swift
//  YoPDFUITests
//
//  Focused real-app Drag & Drop smoke test for the native pane drag pipeline
//  (PR #51 verification). Exercises the AppKit drag session end to end:
//  handle pickup, drop validation, and layout commit through SwiftUI drop
//  delegates.
//  Apache-2.0 Open Source License.
//

import XCTest
import PDFKit

@MainActor
final class PaneDragDropUITests: XCTestCase {

    private func launchTwoPaneWorkspace() throws -> (app: XCUIApplication, window: XCUIElement, fixtureURL: URL) {
        let fixtureURL = try PDFFixtureFactory.writeTemporaryPDF(
            pageCount: 6,
            named: "drag-drop-smoke",
            text: { pageIndex in
                "Drag smoke page \(pageIndex + 1) of 6. Pane drag and drop verification document."
            }
        )

        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["YOPDF_SCREENSHOT_PDF"] = fixtureURL.path
        app.launch()

        guard app.windows.firstMatch.waitForExistence(timeout: 20),
              app.staticTexts[fixtureURL.lastPathComponent].waitForExistence(timeout: 20)
        else {
            throw NSError(domain: "PaneDragDropUITests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The reader window did not open the smoke PDF."
            ])
        }

        let splitRightButton = app.buttons["pdf-split-right-button"]
        XCTAssertTrue(splitRightButton.waitForExistence(timeout: 10))
        splitRightButton.click()
        XCTAssertTrue(
            app.buttons["Vertical split divider"].waitForExistence(timeout: 10),
            "A two-pane side-by-side layout shows a vertical divider."
        )
        return (app, app.windows.firstMatch, fixtureURL)
    }

    /// The leftmost pane drag handle in the current two-pane layout.
    private func leftmostPaneHandle(in app: XCUIApplication) -> XCUIElement {
        let handles = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'pane-drag-handle'"))
        var best: XCUIElement?
        for index in 0..<max(handles.count, 0) {
            let handle = handles.element(boundBy: index)
            guard handle.exists else { continue }
            if let current = best, current.frame.minX <= handle.frame.minX { continue }
            best = handle
        }
        return best ?? handles.element(boundBy: 0)
    }

    /// Real-app smoke: drag Pane A's handle onto Pane B's lower half and
    /// verify the reorder commits — the divider flips from the side-by-side
    /// "Vertical split divider" to the stacked "Horizontal split divider".
    func testPaneHandleDragCommitsIntraTabReorder() throws {
        let (app, window, fixtureURL) = try launchTwoPaneWorkspace()
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: fixtureURL.deletingLastPathComponent())
        }

        let sourceHandle = leftmostPaneHandle(in: app)
        XCTAssertTrue(sourceHandle.waitForExistence(timeout: 10), "Each pane exposes a drag handle.")

        // Drop into the lower half of the right-hand pane.
        let dropPoint = window.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.80))
        sourceHandle
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.15, thenDragTo: dropPoint)

        XCTAssertTrue(
            app.buttons["Horizontal split divider"].waitForExistence(timeout: 10),
            "Dropping Pane A below Pane B must commit the intra-tab reorder."
        )
        XCTAssertFalse(
            app.buttons["Vertical split divider"].exists,
            "The side-by-side divider is gone after the reorder."
        )
    }

    /// A drag released outside every drop target must end without mutating
    /// the layout and leave the panes interactive.
    func testDragReleasedOutsideTargetsLeavesLayoutUnchanged() throws {
        let (app, window, fixtureURL) = try launchTwoPaneWorkspace()
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: fixtureURL.deletingLastPathComponent())
        }

        let sourceHandle = leftmostPaneHandle(in: app)
        XCTAssertTrue(sourceHandle.waitForExistence(timeout: 10), "Each pane exposes a drag handle.")

        // Release over the tab strip, outside every pane drop target.
        let outsidePoint = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03))
        sourceHandle
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.15, thenDragTo: outsidePoint)

        // The layout must be untouched and the panes still interactive.
        XCTAssertTrue(
            app.buttons["Vertical split divider"].waitForExistence(timeout: 5),
            "A cancelled drag must not mutate the layout."
        )
        let handles = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'pane-drag-handle'"))
        XCTAssertGreaterThanOrEqual(handles.count, 2, "Both panes survive a cancelled drag.")

        // The active pane still accepts navigation after the cancelled drag.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).click()
        app.typeKey(.downArrow, modifierFlags: .command)
        XCTAssertTrue(
            app.staticTexts["2 / 6"].waitForExistence(timeout: 10),
            "The pane still navigates after a cancelled drag."
        )
    }

    /// Real-app regression: dragging a single-pane PDF tab filename
    /// horizontally along the tab strip must reorder the tabs.
    func testDraggingSinglePaneTabFilenameReordersTabs() throws {
        let runID = UUID().uuidString
        let firstURL = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 2, named: "tab-alpha-\(runID)")
        let secondURL = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 2, named: "tab-beta-\(runID)")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }

        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["YOPDF_SCREENSHOT_PDF"] = firstURL.path
        app.launch()
        defer { app.terminate() }
        app.activate()

        let firstTab = app.buttons[firstURL.lastPathComponent]
        XCTAssertTrue(firstTab.waitForExistence(timeout: 20), "First PDF tab must appear.")

        app.open(secondURL)
        let secondTab = app.buttons[secondURL.lastPathComponent]
        XCTAssertTrue(secondTab.waitForExistence(timeout: 15), "Second PDF tab must appear.")
        XCTAssertLessThan(firstTab.frame.minX, secondTab.frame.minX)

        // Drag the second tab's filename to the left of the first tab.
        let beforeFirst = firstTab.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        secondTab
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.15, thenDragTo: beforeFirst)

        let movedLeft = waitUntil {
            secondTab.exists && firstTab.exists && secondTab.frame.minX < firstTab.frame.minX
        }
        XCTAssertTrue(movedLeft, "Dragging a tab filename left must reorder it before the first tab.")
        XCTAssertTrue(secondTab.isSelected, "The dragged tab must become active on release.")

        // Drag the same tab back to the right of the other tab.
        let afterFirst = firstTab.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        secondTab
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.15, thenDragTo: afterFirst)

        let movedBack = waitUntil {
            secondTab.exists && firstTab.exists && firstTab.frame.minX < secondTab.frame.minX
        }
        XCTAssertTrue(movedBack, "Dragging a tab filename right must reorder it after the other tab.")
    }

    /// Real-app regression: dragging a single-pane tab vertically out of the tab
    /// strip into the reader content must still tear out into a split pane.
    func testDraggingSinglePaneTabDownIntoPaneCommitsSplit() throws {
        let runID = UUID().uuidString
        let firstURL = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 2, named: "tear-alpha-\(runID)")
        let secondURL = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 2, named: "tear-beta-\(runID)")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }

        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["YOPDF_SCREENSHOT_PDF"] = firstURL.path
        app.launch()
        defer { app.terminate() }
        app.activate()

        let window = app.windows.firstMatch
        let firstTab = app.buttons[firstURL.lastPathComponent]
        XCTAssertTrue(firstTab.waitForExistence(timeout: 20))

        app.open(secondURL)
        let secondTab = app.buttons[secondURL.lastPathComponent]
        XCTAssertTrue(secondTab.waitForExistence(timeout: 15))

        // Drag the inactive first tab downward onto the right edge of the active pane.
        let rightDropPoint = window.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.55))
        firstTab
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.15, thenDragTo: rightDropPoint)

        XCTAssertTrue(
            app.buttons["Vertical split divider"].waitForExistence(timeout: 10),
            "Dragging a single-pane tab vertically onto a pane must split it side-by-side."
        )
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }
}
