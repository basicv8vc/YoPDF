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

import AppKit
import CoreGraphics
import PDFKit
import XCTest

@MainActor
final class PaneDragDropUITests: XCTestCase {

    private func applicationURL() throws -> URL {
        var directory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("YoPDF.app")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw NSError(domain: "PaneDragDropUITests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not find YoPDF.app beside the test runner."
        ])
    }

    @discardableResult
    private func bringToForeground(_ app: XCUIApplication, at applicationURL: URL) -> Bool {
        guard let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier else {
            XCTFail("The built YoPDF app should have a bundle identifier.")
            return false
        }
        guard let process = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first(where: { $0.bundleURL?.standardizedFileURL == applicationURL.standardizedFileURL }) else {
            XCTFail("YoPDF should be running before UI interaction.")
            return false
        }
        _ = process.activate(options: [.activateAllWindows])
        app.activate()
        let foreground = waitUntil {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier
        }
        XCTAssertTrue(foreground, "The built YoPDF process should be frontmost before drag/key events are sent.")
        return foreground
    }

    private func launchApp(
        arguments: [String] = []
    ) async throws -> (app: XCUIApplication, applicationURL: URL) {
        let appURL = try applicationURL()
        guard let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier else {
            throw NSError(domain: "PaneDragDropUITests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The built YoPDF app should have a bundle identifier."
            ])
        }
        let app = XCUIApplication(bundleIdentifier: bundleIdentifier)
        if app.state != .notRunning {
            app.terminate()
            _ = app.wait(for: .notRunning, timeout: 10)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"] + arguments
        let process = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        XCTAssertEqual(process.bundleURL?.standardizedFileURL, appURL.standardizedFileURL)
        _ = process.activate(options: [.activateAllWindows])
        app.activate()
        _ = bringToForeground(app, at: appURL)
        return (app, appURL)
    }

    private func launchTwoPaneWorkspace() async throws -> (app: XCUIApplication, applicationURL: URL, window: XCUIElement, fixtureURL: URL) {
        let fixtureURL = try PDFFixtureFactory.writeTemporaryPDF(
            pageCount: 6,
            named: "drag-drop-smoke",
            text: { pageIndex in
                "Drag smoke page \(pageIndex + 1) of 6. Pane drag and drop verification document."
            }
        )

        let (app, appURL) = try await launchApp()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20), "The reader window should appear before opening the smoke PDF.")

        let openConfig = NSWorkspace.OpenConfiguration()
        openConfig.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        _ = try await NSWorkspace.shared.open([fixtureURL], withApplicationAt: appURL, configuration: openConfig)

        guard app.buttons[fixtureURL.lastPathComponent].waitForExistence(timeout: 20) else {
            throw NSError(domain: "PaneDragDropUITests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The reader window did not open the smoke PDF."
            ])
        }
        _ = bringToForeground(app, at: appURL)

        let splitRightButton = app.buttons["pdf-split-right-button"]
        XCTAssertTrue(splitRightButton.waitForExistence(timeout: 10))
        splitRightButton.click()
        XCTAssertTrue(
            app.buttons["Vertical split divider"].waitForExistence(timeout: 10),
            "A two-pane side-by-side layout shows a vertical divider."
        )
        return (app, appURL, app.windows.firstMatch, fixtureURL)
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
    func testPaneHandleDragCommitsIntraTabReorder() async throws {
        let (app, appURL, window, fixtureURL) = try await launchTwoPaneWorkspace()
        defer {
            app.terminate()
            _ = app.wait(for: .notRunning, timeout: 5)
            try? FileManager.default.removeItem(at: fixtureURL.deletingLastPathComponent())
        }

        let sourceHandle = leftmostPaneHandle(in: app)
        XCTAssertTrue(sourceHandle.waitForExistence(timeout: 10), "Each pane exposes a drag handle.")
        guard bringToForeground(app, at: appURL) else { return }

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
    func testDragReleasedOutsideTargetsLeavesLayoutUnchanged() async throws {
        let (app, appURL, window, fixtureURL) = try await launchTwoPaneWorkspace()
        defer {
            app.terminate()
            _ = app.wait(for: .notRunning, timeout: 5)
            try? FileManager.default.removeItem(at: fixtureURL.deletingLastPathComponent())
        }

        let sourceHandle = leftmostPaneHandle(in: app)
        XCTAssertTrue(sourceHandle.waitForExistence(timeout: 10), "Each pane exposes a drag handle.")
        guard bringToForeground(app, at: appURL) else { return }

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

    private func launchTwoTabWorkspace(
        prefix: String
    ) async throws -> (
        app: XCUIApplication,
        applicationURL: URL,
        window: XCUIElement,
        firstTab: XCUIElement,
        secondTab: XCUIElement,
        cleanup: () -> Void
    ) {
        let runID = UUID().uuidString
        let firstURL = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 2, named: "\(prefix)-alpha-\(runID)")
        let secondURL = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 2, named: "\(prefix)-beta-\(runID)")

        let (app, appURL) = try await launchApp()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20), "The reader window must appear before opening PDFs.")

        let openConfig = NSWorkspace.OpenConfiguration()
        openConfig.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        _ = try await NSWorkspace.shared.open([firstURL], withApplicationAt: appURL, configuration: openConfig)

        let firstTab = app.buttons[firstURL.lastPathComponent]
        XCTAssertTrue(firstTab.waitForExistence(timeout: 20), "First PDF tab must appear.")

        _ = try await NSWorkspace.shared.open([secondURL], withApplicationAt: appURL, configuration: openConfig)

        let secondTab = app.buttons[secondURL.lastPathComponent]
        XCTAssertTrue(secondTab.waitForExistence(timeout: 15), "Second PDF tab must appear.")
        _ = bringToForeground(app, at: appURL)
        XCTAssertTrue(
            waitUntil { firstTab.exists && secondTab.exists && firstTab.frame.minX < secondTab.frame.minX },
            "Two tabs should be laid out in order."
        )

        let cleanup = {
            app.terminate()
            _ = app.wait(for: .notRunning, timeout: 5)
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }
        return (app, appURL, window, firstTab, secondTab, cleanup)
    }

    /// Real-app regression: dragging an inactive single-pane PDF tab filename
    /// horizontally along the tab strip must reorder the tabs and activate it on release.
    func testDraggingSinglePaneTabFilenameReordersTabs() async throws {
        let (app, appURL, _, firstTab, secondTab, cleanup) = try await launchTwoTabWorkspace(prefix: "tab")
        defer { cleanup() }
        guard bringToForeground(app, at: appURL) else { return }

        XCTAssertFalse(firstTab.isSelected, "First tab must start inactive after opening the second PDF.")
        XCTAssertTrue(secondTab.isSelected, "Second tab starts active after opening the second PDF.")

        // Drag the inactive first tab's filename to the right of the active second tab.
        // Drag the inactive first tab's filename to the right of the active second tab.
        let afterSecond = secondTab.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        firstTab
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.15, thenDragTo: afterSecond)

        let movedRight = waitUntil {
            firstTab.exists && secondTab.exists && secondTab.frame.minX < firstTab.frame.minX
        }
        XCTAssertTrue(movedRight, "Dragging an inactive tab filename right must reorder it after the second tab.")
        XCTAssertTrue(firstTab.isSelected, "The dragged inactive tab must become active on release.")

        // Drag the same tab back to the left of the other tab.
        let beforeSecond = secondTab.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        firstTab
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.15, thenDragTo: beforeSecond)

        let movedBack = waitUntil {
            firstTab.exists && secondTab.exists && firstTab.frame.minX < secondTab.frame.minX
        }
        XCTAssertTrue(movedBack, "Dragging a tab filename left must reorder it before the other tab.")
    }

    /// Real-app regression: dragging a multi-pane tab horizontally in the
    /// unified titlebar row must still reorder tabs cleanly without tearing out
    /// or dragging the hosting window.
    func testDraggingMultiPaneTabFilenameReordersTabs() async throws {
        let (app, appURL, _, firstTab, secondTab, cleanup) = try await launchTwoTabWorkspace(prefix: "multipane-tab")
        defer { cleanup() }
        guard bringToForeground(app, at: appURL) else { return }

        XCTAssertTrue(secondTab.isSelected)
        let splitRightButton = app.buttons["pdf-split-right-button"]
        XCTAssertTrue(splitRightButton.waitForExistence(timeout: 10))
        splitRightButton.click()
        XCTAssertTrue(
            app.buttons["Vertical split divider"].waitForExistence(timeout: 10),
            "Splitting the second tab makes it a multi-pane tab."
        )

        let beforeFirst = firstTab.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        secondTab
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.15, thenDragTo: beforeFirst)

        let movedLeft = waitUntil {
            firstTab.exists && secondTab.exists && secondTab.frame.minX < firstTab.frame.minX
        }
        XCTAssertTrue(
            movedLeft,
            "Dragging a multi-pane tab left in the unified titlebar must reorder it before the first tab."
        )

        let afterFirst = firstTab.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        secondTab
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.15, thenDragTo: afterFirst)

        let movedBack = waitUntil {
            firstTab.exists && secondTab.exists && firstTab.frame.minX < secondTab.frame.minX
        }
        XCTAssertTrue(
            movedBack,
            "Dragging a multi-pane tab right in the unified titlebar must reorder it after the other tab."
        )
    }

    /// Real-app regression: dragging a single-pane tab vertically out of the tab
    /// strip into the reader content must still tear out into a split pane.
    func testDraggingSinglePaneTabDownIntoPaneCommitsSplit() async throws {
        let (app, appURL, window, firstTab, _, cleanup) = try await launchTwoTabWorkspace(prefix: "tear")
        defer { cleanup() }
        guard bringToForeground(app, at: appURL) else { return }

        // Drag the inactive first tab downward onto the right edge of the active pane.
        let rightEdgeTarget = window.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.55))
        firstTab
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.15, thenDragTo: rightEdgeTarget)

        XCTAssertTrue(
            app.buttons["Vertical split divider"].waitForExistence(timeout: 10),
            "Dragging a single-pane tab vertically onto a pane must split it side-by-side."
        )
    }

    /// Real-app regression: starting a horizontal tab reorder and then tearing
    /// vertically into the PDF content must cancel reorder and commit a split.
    func testDraggingSinglePaneTabHorizontallyThenDownIntoPaneCommitsSplit() async throws {
        let (app, appURL, window, firstTab, secondTab, cleanup) = try await launchTwoTabWorkspace(prefix: "combo")
        defer { cleanup() }
        guard bringToForeground(app, at: appURL) else { return }

        let start = CGPoint(x: firstTab.frame.midX, y: firstTab.frame.midY)
        let horizontalMid = CGPoint(x: secondTab.frame.midX, y: firstTab.frame.midY)
        let dropPoint = CGPoint(
            x: window.frame.minX + window.frame.width * 0.88,
            y: window.frame.minY + window.frame.height * 0.55
        )
        try performMultiSegmentDrag(from: start, through: [horizontalMid, dropPoint])

        XCTAssertTrue(
            app.buttons["Vertical split divider"].waitForExistence(timeout: 10),
            "Tearing vertically after a horizontal reorder drag must transition to a native pane split."
        )
    }

    /// Real-app regression: pressing Escape during a horizontal tab reorder must
    /// cancel the reorder and preserve both the original tab order and active tab.
    func testDraggingSinglePaneTabEscapeCancelsReorder() async throws {
        let (app, appURL, _, firstTab, secondTab, cleanup) = try await launchTwoTabWorkspace(prefix: "esc")
        defer { cleanup() }
        guard bringToForeground(app, at: appURL) else { return }

        XCTAssertFalse(firstTab.isSelected)
        XCTAssertTrue(secondTab.isSelected)

        let start = CGPoint(x: firstTab.frame.midX, y: firstTab.frame.midY)
        let horizontalPastSecond = CGPoint(x: secondTab.frame.maxX - 8, y: firstTab.frame.midY)
        try performMultiSegmentDrag(
            from: start,
            through: [horizontalPastSecond],
            pressEscapeBeforeRelease: true
        )

        XCTAssertTrue(
            waitUntil { firstTab.exists && secondTab.exists && firstTab.frame.minX < secondTab.frame.minX },
            "Pressing Escape during tab drag must preserve the original tab order."
        )
        XCTAssertTrue(secondTab.isSelected, "Cancelling a drag with Escape must keep the previously active tab selected.")
        XCTAssertFalse(firstTab.isSelected)
    }

    private func performMultiSegmentDrag(
        from start: CGPoint,
        through waypoints: [CGPoint],
        pressEscapeBeforeRelease: Bool = false
    ) throws {
        let down = try XCTUnwrap(
            CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: start,
                mouseButton: .left
            )
        )
        down.post(tap: .cghidEventTap)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        var current = start
        for target in waypoints {
            let steps = 10
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let point = CGPoint(
                    x: current.x + (target.x - current.x) * t,
                    y: current.y + (target.y - current.y) * t
                )
                let drag = try XCTUnwrap(
                    CGEvent(
                        mouseEventSource: nil,
                        mouseType: .leftMouseDragged,
                        mouseCursorPosition: point,
                        mouseButton: .left
                    )
                )
                drag.post(tap: .cghidEventTap)
                RunLoop.current.run(until: Date().addingTimeInterval(0.015))
            }
            current = target
        }

        if pressEscapeBeforeRelease {
            let keyDown = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true))
            let keyUp = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false))
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        let up = try XCTUnwrap(
            CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: current,
                mouseButton: .left
            )
        )
        up.post(tap: .cghidEventTap)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
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
