import AppKit
import XCTest

/// End-to-end coverage of the terminal-style tab shortcuts. The unit tests
/// cover the wrap-around arithmetic; these tests press the real keys in the
/// running app so the menu key equivalents and focused-window actions are
/// exercised through AppKit.
@MainActor
final class TabShortcutUITests: XCTestCase {

    func testTabShortcutsCreateTabsAndCycleInBothDirections() async throws {
        let applicationURL = try applicationURL()
        let app = try application(at: applicationURL)
        defer { app.terminate() }
        try await launch(app, at: applicationURL)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "The reader window should appear.")
        guard bringToForeground(app, at: applicationURL) else { return }

        // Close buttons share the "workspace-tab-" identifier prefix, so they
        // are excluded to leave just the selectable tab titles.
        let tabButtons = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND NOT identifier BEGINSWITH %@",
            "workspace-tab-", "workspace-tab-close-"
        ))
        XCTAssertTrue(waitForTabCount(1, in: tabButtons), "A fresh workspace has one tab.\n\(app.debugDescription)")
        XCTAssertTrue(isTabSelected(0, in: tabButtons))

        // ⌘T creates a new tab and selects it.
        app.typeKey("t", modifierFlags: [.command])
        XCTAssertTrue(waitForTabCount(2, in: tabButtons), "⌘T should create a second tab.")
        XCTAssertTrue(isTabSelected(1, in: tabButtons), "The new tab should become active.")

        app.typeKey("t", modifierFlags: [.command])
        XCTAssertTrue(waitForTabCount(3, in: tabButtons), "⌘T should create a third tab.")
        XCTAssertTrue(isTabSelected(2, in: tabButtons))

        // ⇧⌘] walks right and wraps from the rightmost tab to the leftmost.
        for expected in [0, 1, 2, 0] {
            app.typeKey("]", modifierFlags: [.command, .shift])
            XCTAssertTrue(
                waitForSelectedTab(expected, in: tabButtons),
                "⇧⌘] should select tab \(expected), including the wrap-around.\n\(app.debugDescription)"
            )
        }

        // ⇧⌘[ walks left and wraps from the leftmost tab to the rightmost.
        for expected in [2, 1, 0, 2] {
            app.typeKey("[", modifierFlags: [.command, .shift])
            XCTAssertTrue(
                waitForSelectedTab(expected, in: tabButtons),
                "⇧⌘[ should select tab \(expected), including the wrap-around.\n\(app.debugDescription)"
            )
        }

        XCTAssertEqual(tabButtons.count, 3, "Navigation must not create or close tabs.")
    }

    private func applicationURL() throws -> URL {
        var directory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("YoPDF.app")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw NSError(domain: "TabShortcutUITests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not find YoPDF.app beside the test runner."
        ])
    }

    private func application(at applicationURL: URL) throws -> XCUIApplication {
        guard let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier else {
            throw NSError(domain: "TabShortcutUITests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The built YoPDF app should have a bundle identifier."
            ])
        }
        return XCUIApplication(bundleIdentifier: bundleIdentifier)
    }

    private func launch(_ app: XCUIApplication, at applicationURL: URL) async throws {
        if app.state != .notRunning {
            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 10),
                          "An existing YoPDF process should exit before the shortcut test starts.")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        let process = try await NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration
        )
        XCTAssertEqual(process.bundleURL?.standardizedFileURL, applicationURL.standardizedFileURL,
                       "The UI test should launch the built YoPDF app, not another copy.")
        _ = process.activate(options: [.activateAllWindows])
        app.activate()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != process.processIdentifier {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, process.processIdentifier,
                       "The launched YoPDF process should be frontmost before key events are sent.")
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
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("YoPDF did not become the frontmost app; another app may be intercepting key events.")
        return false
    }

    private func waitForTabCount(_ expected: Int, in buttons: XCUIElementQuery) -> Bool {
        waitUntil { buttons.count == expected }
    }

    private func isTabSelected(_ index: Int, in buttons: XCUIElementQuery) -> Bool {
        guard buttons.count > index else { return false }
        return buttons.allElementsBoundByIndex[index].isSelected
    }

    private func waitForSelectedTab(_ index: Int, in buttons: XCUIElementQuery) -> Bool {
        waitUntil { self.isTabSelected(index, in: buttons) }
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
