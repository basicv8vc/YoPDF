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
        let app = try application(at: applicationURL)
        defer { app.terminate() }
        try await launch(app, at: applicationURL)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let firstTab = app.buttons[first.lastPathComponent]
        try await open(first, with: applicationURL, in: app)
        guard bringToForeground(app, at: applicationURL) else { return }
        XCTAssertTrue(firstTab.waitForExistence(timeout: 15))
        try await open(second, with: applicationURL, in: app)
        let secondTab = app.buttons[second.lastPathComponent]
        XCTAssertTrue(secondTab.waitForExistence(timeout: 10))
        guard bringToForeground(app, at: applicationURL) else { return }

        let addNote = app.buttons.matching(identifier: "note.text.badge.plus").firstMatch
        XCTAssertTrue(addNote.waitForExistence(timeout: 5))
        addNote.click()
        XCTAssertTrue(app.buttons["Cancel Note"].waitForExistence(timeout: 5),
                      "Add Note should enter page placement mode.")
        let readerWindow = app.windows.firstMatch
        XCTAssertTrue(readerWindow.waitForExistence(timeout: 5))
        XCTAssertTrue(readerWindow.isHittable, "The reader window should be in the foreground.")
        XCTAssertTrue(bringToForeground(app, at: applicationURL))
        clickVisiblePDFPage(in: readerWindow)

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

    private func application(at applicationURL: URL) throws -> XCUIApplication {
        guard let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier else {
            throw NSError(domain: "TabCloseUITests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The built YoPDF app should have a bundle identifier."
            ])
        }
        return XCUIApplication(bundleIdentifier: bundleIdentifier)
    }

    private func launch(_ app: XCUIApplication, at applicationURL: URL) async throws {
        if app.state != .notRunning {
            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 10),
                          "An existing YoPDF process should exit before the TabClose test starts.")
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
                       "The launched YoPDF process should become frontmost before UI queries begin.")
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

        XCTFail("YoPDF did not become the frontmost app; another app may be intercepting UI events.")
        return false
    }

    private func clickVisiblePDFPage(in window: XCUIElement) {
        let windowFrame = window.frame
        let documentView = window.scrollViews.allElementsBoundByIndex
            .filter {
                $0.frame.width > windowFrame.width * 0.55
                    && $0.frame.height > windowFrame.height * 0.55
            }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let documentView else {
            XCTFail("The selected reader should expose a visible PDF document scroll view.")
            return
        }
        let documentFrame = documentView.frame
        let target = CGPoint(x: documentFrame.midX, y: documentFrame.minY + documentFrame.height * 0.35)
        window.coordinate(withNormalizedOffset: CGVector(
            dx: (target.x - windowFrame.minX) / windowFrame.width,
            dy: (target.y - windowFrame.minY) / windowFrame.height
        )).click()
    }

    private func open(_ url: URL, with applicationURL: URL, in app: XCUIApplication) async throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        _ = try await NSWorkspace.shared.open(
            [url], withApplicationAt: applicationURL, configuration: configuration
        )
        XCTAssertTrue(bringToForeground(app, at: applicationURL))
        XCTAssertTrue(app.buttons[url.lastPathComponent].waitForExistence(timeout: 10),
                      "The opened PDF should have a workspace tab.")
    }
}
