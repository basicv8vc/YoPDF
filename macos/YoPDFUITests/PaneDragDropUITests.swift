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
}
