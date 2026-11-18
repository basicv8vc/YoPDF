import AppKit
import CoreGraphics
import XCTest

@MainActor
final class UnifiedTitlebarUITests: XCTestCase {

    func testEmptyTitlebarDragAndDoubleClickFillZoomMinimize() async throws {
        // 1. Empty titlebar drag + macOS Fill preference (two double-clicks stay filled).
        do {
            let (app, appURL) = try await launchApp(arguments: [
                "-ApplePersistenceIgnoreState", "YES",
                "-AppleActionOnDoubleClick", "Fill"
            ])
            defer { terminateAndWait(app) }

            let window = app.windows.firstMatch
            let newTabButton = app.buttons["workspace-new-tab"]
            XCTAssertTrue(window.waitForExistence(timeout: 15))
            XCTAssertTrue(newTabButton.waitForExistence(timeout: 10))
            guard bringToForeground(app, at: appURL) else { return }

            try shrinkWindowIfNeeded(window)

            let beforeDrag = window.frame
            let start = emptyTitlebarCoordinate(in: window, plusFrame: newTabButton.frame)
            let targetPoint = CGPoint(
                x: emptyTitlebarPoint(in: window, plusFrame: newTabButton.frame).x + 56,
                y: emptyTitlebarPoint(in: window, plusFrame: newTabButton.frame).y + 42
            )
            let end = coordinate(forScreenPoint: targetPoint, in: window)
            start.press(forDuration: 0.15, thenDragTo: end)
            XCTAssertTrue(waitUntil {
                abs(window.frame.minX - beforeDrag.minX) > 25 || abs(window.frame.minY - beforeDrag.minY) > 20
            }, "Dragging empty titlebar space should move the window. before=\(beforeDrag), after=\(window.frame)")

            let beforeFill = window.frame
            emptyTitlebarCoordinate(in: window, plusFrame: newTabButton.frame).doubleClick()
            XCTAssertTrue(waitUntil {
                window.frame.width > beforeFill.width + 40
            }, "Double-clicking empty titlebar with Fill should expand the window. before=\(beforeFill), after=\(window.frame)")

            let filledFrame = window.frame
            emptyTitlebarCoordinate(in: window, plusFrame: newTabButton.frame).doubleClick()
            try await Task.sleep(nanoseconds: 350_000_000)
            XCTAssertEqual(
                window.frame.width, filledFrame.width, accuracy: 8,
                "Repeating a double-click with Fill should keep the window filled rather than toggling back like Zoom."
            )
        }

        // 2. Maximize (Zoom) preference expands and toggles back to the restored frame.
        do {
            let (app, appURL) = try await launchApp(arguments: [
                "-ApplePersistenceIgnoreState", "YES",
                "-AppleActionOnDoubleClick", "Maximize"
            ])
            defer { terminateAndWait(app) }

            let window = app.windows.firstMatch
            let newTabButton = app.buttons["workspace-new-tab"]
            XCTAssertTrue(window.waitForExistence(timeout: 15))
            XCTAssertTrue(newTabButton.waitForExistence(timeout: 10))
            guard bringToForeground(app, at: appURL) else { return }

            try shrinkWindowIfNeeded(window)

            let initialFrame = window.frame
            emptyTitlebarCoordinate(in: window, plusFrame: newTabButton.frame).doubleClick()
            XCTAssertTrue(waitUntil {
                window.frame.width > initialFrame.width + 40
            }, "Double-clicking empty titlebar with Maximize should zoom the window.")

            emptyTitlebarCoordinate(in: window, plusFrame: newTabButton.frame).doubleClick()
            XCTAssertTrue(waitUntil {
                abs(window.frame.width - initialFrame.width) < 12
            }, "Second double-click with Maximize should restore the original window width.")
        }

        // 3. Minimize preference miniaturizes the window.
        do {
            let (app, appURL) = try await launchApp(arguments: [
                "-ApplePersistenceIgnoreState", "YES",
                "-AppleActionOnDoubleClick", "Minimize"
            ])
            defer { terminateAndWait(app) }

            let window = app.windows.firstMatch
            let newTabButton = app.buttons["workspace-new-tab"]
            XCTAssertTrue(window.waitForExistence(timeout: 15))
            XCTAssertTrue(newTabButton.waitForExistence(timeout: 10))
            guard bringToForeground(app, at: appURL) else { return }

            emptyTitlebarCoordinate(in: window, plusFrame: newTabButton.frame).doubleClick()
            XCTAssertTrue(waitUntil {
                !window.exists || !window.isHittable
            }, "Double-clicking empty titlebar with Minimize should miniaturize the window.")
        }
    }

    func testFullScreenToggleAndTrafficLightLeadingInsetRecovery() async throws {
        let (app, appURL) = try await launchApp()
        defer { terminateAndWait(app) }

        let window = app.windows.firstMatch
        let tabs = workspaceTabButtons(in: app)
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        XCTAssertTrue(tabs.firstMatch.waitForExistence(timeout: 10))
        guard bringToForeground(app, at: appURL) else { return }

        let windowedInset = tabs.firstMatch.frame.minX - window.frame.minX
        XCTAssertGreaterThanOrEqual(windowedInset, 65, "Windowed layout should clear the traffic lights.")

        let windowedWidth = window.frame.width
        toggleFullScreen(in: app, appURL: appURL, expectEnter: true)
        XCTAssertTrue(waitUntil(timeout: 10) {
            window.frame.width > windowedWidth + 40
        }, "Entering fullscreen should expand window width. windowedWidth=\(windowedWidth), current=\(window.frame)")

        // Reveal the top titlebar in fullscreen if auto-hidden, then verify leading inset collapses.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.005)).hover()
        if tabs.firstMatch.waitForExistence(timeout: 3) {
            let fullScreenInset = tabs.firstMatch.frame.minX - window.frame.minX
            XCTAssertLessThan(
                fullScreenInset, 40,
                "Fullscreen mode should collapse traffic-light leading inset. inset=\(fullScreenInset)"
            )
        }

        toggleFullScreen(in: app, appURL: appURL, expectEnter: false)
        XCTAssertTrue(waitUntil(timeout: 10) {
            abs(window.frame.width - windowedWidth) < 20
        }, "Exiting fullscreen should restore windowed size. expected=\(windowedWidth), current=\(window.frame)")

        XCTAssertTrue(tabs.firstMatch.waitForExistence(timeout: 5))
        let restoredInset = tabs.firstMatch.frame.minX - window.frame.minX
        XCTAssertGreaterThanOrEqual(
            restoredInset, 65,
            "Exiting fullscreen should restore traffic-light leading clearance. inset=\(restoredInset)"
        )
    }

    func testNarrowWindowOverflowTabsScrollWithoutScrollBarOrClippingNewTabButton() async throws {
        let (app, appURL) = try await launchApp()
        defer { terminateAndWait(app) }

        let window = app.windows.firstMatch
        let newTabButton = app.buttons["workspace-new-tab"]
        let tabs = workspaceTabButtons(in: app)
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        XCTAssertTrue(newTabButton.waitForExistence(timeout: 10))
        guard bringToForeground(app, at: appURL) else { return }

        // Narrow the window horizontally to force tab strip overflow with multiple tabs.
        let rightEdge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.999, dy: 0.5))
        let narrowTarget = window.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
        rightEdge.press(forDuration: 0.15, thenDragTo: narrowTarget)

        for _ in 0..<6 {
            app.typeKey("t", modifierFlags: .command)
        }
        XCTAssertTrue(waitUntil { tabs.count == 7 }, "Expected 7 tabs after pressing ⌘T six times.")

        let windowFrame = window.frame
        let plusFrame = newTabButton.frame
        XCTAssertLessThanOrEqual(
            plusFrame.maxX, windowFrame.maxX,
            "New Tab (+) button must stay visible inside a narrow window when tabs overflow."
        )

        let titlebarScrollBars = app.scrollBars.allElementsBoundByIndex.filter {
            $0.frame.minY < windowFrame.minY + 46 && $0.frame.width > 0 && $0.frame.height > 0
        }
        XCTAssertTrue(
            titlebarScrollBars.isEmpty,
            "Overflowing tabs in a narrow window must not show a horizontal scrollbar: \(titlebarScrollBars.map(\.frame))"
        )

        // Switching to the next (wrapped-around first) tab remains responsive and single-row.
        app.typeKey("]", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil { tabs.element(boundBy: 0).isSelected })
        XCTAssertLessThan(
            tabs.element(boundBy: 0).frame.minY - windowFrame.minY, 16,
            "Tabs must remain in the top unified titlebar row during overflow."
        )
    }

    func testSparkleUpdateIndicatorAndMultiWindowIsolation() async throws {
        let (app, appURL) = try await launchApp(arguments: [
            "-ApplePersistenceIgnoreState", "YES",
            "--yopdf-preview-update=99.0.0"
        ])
        defer { terminateAndWait(app) }

        let window = app.windows.firstMatch
        let newTabButton = app.buttons["workspace-new-tab"]
        let updateButton = app.buttons["titlebar-update-indicator"]
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        XCTAssertTrue(newTabButton.waitForExistence(timeout: 10))
        XCTAssertTrue(updateButton.waitForExistence(timeout: 10), "Preview update flag should surface the titlebar update indicator.")
        guard bringToForeground(app, at: appURL) else { return }

        let windowFrame = window.frame
        let plusFrame = newTabButton.frame
        let updateFrame = updateButton.frame
        XCTAssertGreaterThan(updateFrame.minX, plusFrame.maxX, "Update indicator should sit to the right of the + button.")
        XCTAssertLessThanOrEqual(updateFrame.maxX, windowFrame.maxX, "Update indicator should stay inside window trailing bounds.")
        XCTAssertLessThan(abs(updateFrame.midY - plusFrame.midY), 6, "Update indicator should align on the unified titlebar row.")

        // Multi-window isolation: ⌘N creates a second window with independent tabs, title & update indicator.
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(
            waitUntil(timeout: 8) {
                app.buttons.matching(identifier: "workspace-new-tab").count == 2
            },
            "⌘N should open a second reader window."
        )
        XCTAssertEqual(
            app.buttons.matching(identifier: "titlebar-update-indicator").count, 2,
            "Both windows should surface the Sparkle titlebar update indicator."
        )

        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(
            waitUntil { self.workspaceTabButtons(in: app).count == 3 },
            "⌘T in the focused second window should add a tab only there (2 + 1 = 3 total tabs across 2 windows)."
        )
        XCTAssertEqual(app.windows.element(boundBy: 0).title, "YoPDF")
        XCTAssertEqual(app.windows.element(boundBy: 1).title, "YoPDF")

        // Verify clicking the Sparkle titlebar indicator responds cleanly when enabled.
        let firstUpdateButton = app.buttons.matching(identifier: "titlebar-update-indicator").firstMatch
        if waitUntil(timeout: 5, condition: { firstUpdateButton.isEnabled }) {
            firstUpdateButton.click()
            try await Task.sleep(nanoseconds: 300_000_000)
            if app.dialogs.firstMatch.exists || app.sheets.firstMatch.exists {
                app.typeKey(.escape, modifierFlags: [])
            }
        }
    }

    // MARK: - Helpers

    private func applicationURL() throws -> URL {
        var directory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("YoPDF.app")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw NSError(domain: "UnifiedTitlebarUITests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not find YoPDF.app beside the test runner."
        ])
    }

    private func launchApp(arguments: [String] = ["-ApplePersistenceIgnoreState", "YES"]) async throws -> (XCUIApplication, URL) {
        let appURL = try applicationURL()
        guard let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier else {
            throw NSError(domain: "UnifiedTitlebarUITests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The built YoPDF app should have a bundle identifier."
            ])
        }
        let existing = XCUIApplication(bundleIdentifier: bundleIdentifier)
        if existing.state != .notRunning {
            existing.terminate()
            _ = existing.wait(for: .notRunning, timeout: 10)
        }
        let app = XCUIApplication(url: appURL)
        app.launchArguments = arguments
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 20)
        _ = bringToForeground(app, at: appURL)
        return (app, appURL)
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
        XCTAssertTrue(foreground, "YoPDF must be frontmost before sending key or pointer events.")
        return foreground
    }

    private func workspaceTabButtons(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND NOT identifier BEGINSWITH %@",
            "workspace-tab-", "workspace-tab-close-"
        ))
    }

    private func emptyTitlebarPoint(in window: XCUIElement, plusFrame: CGRect) -> CGPoint {
        let windowFrame = window.frame
        return CGPoint(
            x: min(plusFrame.maxX + 48, windowFrame.maxX - 96),
            y: plusFrame.midY
        )
    }

    private func coordinate(forScreenPoint point: CGPoint, in window: XCUIElement) -> XCUICoordinate {
        let windowFrame = window.frame
        return window.coordinate(withNormalizedOffset: CGVector(
            dx: (point.x - windowFrame.minX) / windowFrame.width,
            dy: (point.y - windowFrame.minY) / windowFrame.height
        ))
    }

    private func emptyTitlebarCoordinate(in window: XCUIElement, plusFrame: CGRect) -> XCUICoordinate {
        coordinate(forScreenPoint: emptyTitlebarPoint(in: window, plusFrame: plusFrame), in: window)
    }

    private func shrinkWindowIfNeeded(_ window: XCUIElement) throws {
        guard let visibleWidth = NSScreen.main?.visibleFrame.width,
              window.frame.width > visibleWidth - 140
        else { return }
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 0.999, dy: 0.999))
        let smaller = window.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.65))
        corner.press(forDuration: 0.15, thenDragTo: smaller)
    }

    private func toggleFullScreen(in app: XCUIApplication, appURL: URL, expectEnter: Bool) {
        guard bringToForeground(app, at: appURL) else { return }
        _ = expectEnter
        app.typeKey("f", modifierFlags: [.command, .control])
    }

    private func terminateAndWait(_ app: XCUIApplication) {
        app.terminate()
        _ = app.wait(for: .notRunning, timeout: 5)
    }

    private func waitUntil(timeout: TimeInterval = 5, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }
}
