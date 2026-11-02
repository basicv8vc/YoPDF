import AppKit
import XCTest

@MainActor
final class TabCloseUITests: XCTestCase {

    func testClosingBackgroundTabWithDraftCanBeCancelled() async throws {
        let runID = UUID().uuidString
        let first = try PDFFixtureFactory.writeTemporaryPDF(named: "close-first-\(runID)")
        let second = try PDFFixtureFactory.writeTemporaryPDF(named: "close-second-\(runID)")
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }

        let applicationURL = try applicationURL()
        let app = XCUIApplication(url: applicationURL)
        defer { app.terminate() }
        configureFreshLaunch(app)
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        guard bringToForeground(app, at: applicationURL) else { return }

        let firstTab = app.buttons[first.lastPathComponent]
        try await open(first, with: applicationURL)
        guard bringToForeground(app, at: applicationURL) else { return }
        XCTAssertTrue(firstTab.waitForExistence(timeout: 15))
        try await open(second, with: applicationURL)
        let secondTab = app.buttons[second.lastPathComponent]
        XCTAssertTrue(secondTab.waitForExistence(timeout: 10))
        guard bringToForeground(app, at: applicationURL) else { return }

        let addNote = app.buttons["Add Note"]
        XCTAssertTrue(addNote.waitForExistence(timeout: 5))
        addNote.click()
        XCTAssertTrue(app.buttons["Cancel Note"].waitForExistence(timeout: 5),
                      "Add Note should enter page placement mode.")
        let readerWindow = app.windows.firstMatch
        XCTAssertTrue(readerWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(readerWindow.isHittable, "The reader window should be in the foreground.")
        readerWindow.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).click()

        let composer = app.descendants(matching: .any)
            .matching(identifier: "pdf-thought-capture-popover").firstMatch
        if !composer.waitForExistence(timeout: 5) {
            XCTContext.runActivity(named: "Note placement accessibility snapshot") { activity in
                let attachment = XCTAttachment(string: app.debugDescription)
                attachment.name = "Reader hierarchy after note placement click"
                activity.add(attachment)
            }
            XCTFail("Clicking the visible page should open its note draft.\n\(app.debugDescription)")
            return
        }
        let identifiedNoteInput = app.textFields
            .matching(identifier: "pdf-compact-note-input")
            .firstMatch
        let noteInput: XCUIElement
        if identifiedNoteInput.waitForExistence(timeout: 3) {
            noteInput = identifiedNoteInput
        } else {
            // The source identifier is currently overridden in SwiftUI's
            // runtime AX tree. Record the observed text-field identifiers and
            // continue through the accessible field label so the close/cancel
            // behavior still gets exercised.
            let visibleFields = app.textFields.allElementsBoundByIndex.map {
                "identifier=\($0.identifier) label=\($0.label)"
            }.joined(separator: "\n")
            XCTContext.runActivity(named: "Note field identifier lookup") { activity in
                let attachment = XCTAttachment(string: "Exact identifier matched: false\nVisible text fields:\n\(visibleFields)")
                attachment.name = "Runtime note TextField identifiers"
                activity.add(attachment)
            }
            noteInput = app.textFields.matching(
                NSPredicate(format: "label == %@", "Note contents")
            ).firstMatch
        }
        XCTAssertTrue(noteInput.waitForExistence(timeout: 5), "The note TextField should be accessible.")
        noteInput.click()
        let draftText = "Draft belongs to the background tab"
        noteInput.typeText(draftText)
        XCTAssertEqual(noteInput.value as? String, draftText, "Typing should update the owning tab's draft.")

        guard bringToForeground(app, at: applicationURL) else { return }
        firstTab.click()
        let closeSecond = app.buttons["Close \(second.lastPathComponent)"]
        XCTAssertTrue(closeSecond.waitForExistence(timeout: 5))
        closeSecond.click()

        // macOS exposes this SwiftUI `.alert` as a Sheet in XCTest's
        // accessibility hierarchy.
        let confirmation = app.sheets.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5),
                      "Closing the draft tab should ask before losing it.")
        let cancel = confirmation.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Closing the draft tab should ask before losing it.")
        cancel.click()

        XCTAssertTrue(secondTab.waitForExistence(timeout: 5), "Cancel must keep the requested tab open.")
        XCTAssertTrue(noteInput.waitForExistence(timeout: 5), "Cancel must keep the draft on its owning tab.")
        XCTAssertEqual(
            noteInput.value as? String,
            draftText,
            "Cancel must preserve the draft text."
        )
    }

    private func applicationURL() throws -> URL {
        var directory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("YoPDF.app")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw NSError(domain: "TabCloseUITests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not find YoPDF.app beside the test runner."
        ])
    }

    private func configureFreshLaunch(_ app: XCUIApplication) {
        if app.state != .notRunning {
            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 10),
                          "An existing YoPDF process should exit before the TabClose test starts.")
        }
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    }

    @discardableResult
    private func bringToForeground(_ app: XCUIApplication, at applicationURL: URL) -> Bool {
        guard let process = NSRunningApplication.runningApplications(
            withBundleIdentifier: "dev.yopdf.provisional.debug.uitest"
        ).first(where: { $0.bundleURL?.standardizedFileURL == applicationURL.standardizedFileURL }) else {
            XCTFail("YoPDF should be running before UI interaction.")
            return false
        }

        app.activate()
        _ = process.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTFail("YoPDF did not become the frontmost app; another app may be intercepting UI events.")
        return false
    }

    private func open(_ url: URL, with applicationURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        _ = try await NSWorkspace.shared.open(
            [url], withApplicationAt: applicationURL, configuration: configuration
        )
    }
}
