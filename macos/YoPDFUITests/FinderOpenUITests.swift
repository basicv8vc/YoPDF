import AppKit
import XCTest

@MainActor
final class FinderOpenUITests: XCTestCase {

    func testFinderOpenFromColdLaunchLoadsRequestedPDF() async throws {
        let runID = UUID().uuidString
        let first = try PDFFixtureFactory.writeTemporaryPDF(named: "finder-cold-\(runID)")
        defer { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) }

        let applicationURL = try applicationURL()
        let app = XCUIApplication(url: applicationURL)
        defer { app.terminate() }
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]

        app.open(first)
        XCTAssertTrue(app.buttons[first.lastPathComponent].waitForExistence(timeout: 15))
        assertWorkspaceTabs([first], in: app)
    }

    func testFinderBatchAndRapidOpensCreateTabsInOrderAndFailuresPreserveTabs() async throws {
        let runID = UUID().uuidString
        let first = try PDFFixtureFactory.writeTemporaryPDF(named: "finder-first-\(runID)")
        let second = try PDFFixtureFactory.writeTemporaryPDF(named: "finder-second-\(runID)")
        let third = try PDFFixtureFactory.writeTemporaryPDF(named: "finder-third-\(runID)")
        let fourth = try PDFFixtureFactory.writeTemporaryPDF(named: "finder-fourth-\(runID)")
        let corrupt = try PDFFixtureFactory.writeTemporaryFile(
            named: "finder-corrupt-\(runID).pdf", contents: Data("Not a PDF".utf8)
        )
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: third.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: fourth.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: corrupt.deletingLastPathComponent())
        }

        let applicationURL = try applicationURL()
        let app = XCUIApplication(url: applicationURL)
        defer { app.terminate() }
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        try await open([first, second], with: applicationURL)
        XCTAssertTrue(app.buttons[first.lastPathComponent].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[second.lastPathComponent].waitForExistence(timeout: 10))
        assertWorkspaceTabs([first, second], in: app)

        try await open([third], with: applicationURL)
        try await open([fourth], with: applicationURL)
        XCTAssertTrue(app.buttons[third.lastPathComponent].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[fourth.lastPathComponent].waitForExistence(timeout: 10))
        assertWorkspaceTabs([first, second, third, fourth], in: app)

        try await open([corrupt], with: applicationURL)
        XCTAssertTrue(app.staticTexts["Couldn’t open this document"].waitForExistence(timeout: 5))
        assertWorkspaceTabs([first, second, third, fourth], in: app)
        app.typeKey(.return, modifierFlags: [])

        // Same-window duplicate opens select the original tab without adding
        // a second independently editable session.
        try await open([first], with: applicationURL)
        assertWorkspaceTabs([first, second, third, fourth], in: app)

        // ⌘W closes tabs one at a time; the last tab closes the native window.
        for expectedCount in [3, 2, 1] {
            app.activate()
            app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(waitForTabCount(expectedCount, in: app),
                          "⌘W should leave \(expectedCount) tab(s) in the workspace.")
        }
        app.activate()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitForWindowCount(0, in: app), "⌘W on the last tab closes its window.")

        try await open([first], with: applicationURL)
        XCTAssertTrue(app.buttons[first.lastPathComponent].waitForExistence(timeout: 10),
                      "Finder must create a reader after every workspace window was closed.")
        assertWorkspaceTabs([first], in: app)
    }

    func testNewWindowCreatesAnIndependentWorkspace() throws {
        let applicationURL = try applicationURL()
        let app = XCUIApplication(url: applicationURL)
        defer { app.terminate() }
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(waitForWindowCount(2, in: app), "New Window must create a separate workspace.")
        XCTAssertEqual(tabCount(in: app), 2, "Each empty window starts with one workspace tab.")
    }

    func testCommandTCreatesAnEmptyWorkspaceTab() throws {
        let applicationURL = try applicationURL()
        let app = XCUIApplication(url: applicationURL)
        defer { app.terminate() }
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(waitForTabCount(2, in: app), "⌘T creates an empty workspace tab.")
        XCTAssertEqual(app.buttons.matching(identifier: "workspace-new-tab").count, 1)
    }

    private func applicationURL() throws -> URL {
        var directory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("YoPDF.app")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw NSError(domain: "FinderOpenUITests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not find YoPDF.app beside the test runner."
        ])
    }

    private func open(_ urls: [URL], with applicationURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        _ = try await NSWorkspace.shared.open(
            urls, withApplicationAt: applicationURL, configuration: configuration
        )
    }

    private func assertWorkspaceTabs(_ documents: [URL], in app: XCUIApplication) {
        XCTAssertEqual(app.windows.count, 1, "Finder opens belong to the current workspace window.")
        for document in documents {
            XCTAssertTrue(
                app.buttons[document.lastPathComponent].waitForExistence(timeout: 5),
                "Expected a workspace tab for \(document.lastPathComponent)."
            )
        }
        XCTAssertEqual(tabCount(in: app), documents.count,
                       "Duplicate opens must not create duplicate tabs.")
    }

    private func tabCount(in app: XCUIApplication) -> Int {
        let closeButtons = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "workspace-tab-close-")
        )
        // Every tab gets a close button when there is more than one tab. The
        // last tab closes its window, so it deliberately has no close button.
        return closeButtons.count > 0 ? closeButtons.count : 1
    }

    private func waitForTabCount(_ expected: Int, in app: XCUIApplication) -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if tabCount(in: app) == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    private func waitForWindowCount(_ expected: Int, in app: XCUIApplication) -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if app.windows.count == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }
}
