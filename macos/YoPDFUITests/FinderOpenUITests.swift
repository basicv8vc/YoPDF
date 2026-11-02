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
        configureFreshLaunch(app)

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
        configureFreshLaunch(app)
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(tabCount(in: app), 1, "A fresh reader starts with one empty workspace tab.")

        try await open([first, second], with: applicationURL)
        XCTAssertTrue(app.buttons[first.lastPathComponent].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[second.lastPathComponent].waitForExistence(timeout: 10))
        assertWorkspaceTabs([first, second], expectedTabCount: 2, in: app)

        try await open([third], with: applicationURL)
        try await open([fourth], with: applicationURL)
        XCTAssertTrue(app.buttons[third.lastPathComponent].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[fourth.lastPathComponent].waitForExistence(timeout: 10))
        assertWorkspaceTabs([first, second, third, fourth], expectedTabCount: 4, in: app)

        try await open([corrupt], with: applicationURL)
        let openFailure = app.staticTexts["Couldn’t open this document"]
        XCTAssertTrue(openFailure.waitForExistence(timeout: 5))
        assertWorkspaceTabs([first, second, third, fourth], expectedTabCount: 4, in: app)
        let openFailureSheet = app.sheets.firstMatch
        XCTAssertTrue(openFailureSheet.waitForExistence(timeout: 5),
                      "The corrupt PDF failure should be presented in a dismissible sheet.")
        let dismissOpenFailure = openFailureSheet.buttons["OK"]
        XCTAssertTrue(dismissOpenFailure.waitForExistence(timeout: 5),
                      "The corrupt PDF failure sheet should expose OK.")
        dismissOpenFailure.click()
        XCTAssertFalse(openFailure.waitForExistence(timeout: 2),
                       "The corrupt PDF failure should be dismissed before later Finder actions.")

        // Same-window duplicate opens select the original tab without adding
        // a second independently editable session.
        try await open([first], with: applicationURL)
        assertWorkspaceTabs([first, second, third, fourth], expectedTabCount: 4, in: app)

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
        configureFreshLaunch(app)
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
        configureFreshLaunch(app)
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

    private func configureFreshLaunch(_ app: XCUIApplication) {
        if app.state != .notRunning {
            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 10),
                          "An existing YoPDF process should exit before the Finder test starts.")
        }
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    }

    private func open(_ urls: [URL], with applicationURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        _ = try await NSWorkspace.shared.open(
            urls, withApplicationAt: applicationURL, configuration: configuration
        )
    }

    private func assertWorkspaceTabs(
        _ documents: [URL],
        expectedTabCount: Int? = nil,
        in app: XCUIApplication
    ) {
        let tabButtons = workspaceTabButtons(in: app)
        let closeButtons = workspaceTabCloseButtons(in: app)
        let expectedTabCount = expectedTabCount ?? documents.count
        let expectedCloseButtonCount = expectedTabCount > 1 ? expectedTabCount : 0
        let windowCount = app.windows.count
        let diagnostics = workspaceDiagnostics(
            documents: documents,
            tabButtons: tabButtons,
            closeButtons: closeButtons,
            in: app
        )

        if windowCount != 1
            || tabButtons.count != expectedTabCount
            || closeButtons.count != expectedCloseButtonCount {
            XCTContext.runActivity(named: "Workspace accessibility diagnostics") { activity in
                let attachment = XCTAttachment(string: diagnostics)
                attachment.name = "Workspace tabs and close buttons"
                activity.add(attachment)
            }
        }

        XCTAssertEqual(windowCount, 1,
                       "Finder opens belong to the current workspace window.\n\(diagnostics)")
        for document in documents {
            XCTAssertTrue(
                app.buttons[document.lastPathComponent].waitForExistence(timeout: 5),
                "Expected a workspace tab for \(document.lastPathComponent)."
            )
        }
        XCTAssertEqual(tabButtons.count, expectedTabCount,
                       "Duplicate opens must not create duplicate tabs.\n\(diagnostics)")
        XCTAssertEqual(closeButtons.count, expectedCloseButtonCount,
                       "Each tab in a multi-tab workspace should expose one close button.\n\(diagnostics)")
    }

    private func tabCount(in app: XCUIApplication) -> Int {
        workspaceTabButtons(in: app).count
    }

    private func workspaceTabButtons(in app: XCUIApplication) -> [XCUIElement] {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "workspace-tab-")
        ).allElementsBoundByIndex.filter {
            !$0.identifier.hasPrefix("workspace-tab-close-")
        }
    }

    private func workspaceTabCloseButtons(in app: XCUIApplication) -> [XCUIElement] {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "workspace-tab-close-")
        ).allElementsBoundByIndex
    }

    private func workspaceDiagnostics(
        documents: [URL],
        tabButtons: [XCUIElement],
        closeButtons: [XCUIElement],
        in app: XCUIApplication
    ) -> String {
        let windowDescriptions = app.windows.allElementsBoundByIndex.map {
            "identifier=\($0.identifier) title=\($0.title)"
        }
        let tabDescriptions = tabButtons.map {
            "identifier=\($0.identifier) label=\($0.label)"
        }
        let closeDescriptions = closeButtons.map {
            "identifier=\($0.identifier) label=\($0.label)"
        }
        let pdfDescriptions = documents.map { url in
            "\(url.lastPathComponent) exists=\(FileManager.default.fileExists(atPath: url.path))"
        }

        return [
            "Workspace window count: \(app.windows.count)",
            "Workspace windows:\n\(windowDescriptions.joined(separator: "\n"))",
            "Workspace tab button count: \(tabButtons.count)",
            "Workspace tab buttons (identifier | label):\n\(tabDescriptions.joined(separator: "\n"))",
            "Workspace close button count: \(closeButtons.count)",
            "Workspace close buttons (identifier | label):\n\(closeDescriptions.joined(separator: "\n"))",
            "Fixture PDF files:\n\(pdfDescriptions.joined(separator: "\n"))"
        ].joined(separator: "\n\n")
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
