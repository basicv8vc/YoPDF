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
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["YOPDF_SCREENSHOT_PDF"] = first.path
        app.launch()

        let firstTab = app.buttons[first.lastPathComponent]
        XCTAssertTrue(firstTab.waitForExistence(timeout: 15))
        try await open(second, with: applicationURL)
        let secondTab = app.buttons[second.lastPathComponent]
        XCTAssertTrue(secondTab.waitForExistence(timeout: 10))

        let addNote = app.buttons["Add Note"]
        XCTAssertTrue(addNote.waitForExistence(timeout: 5))
        addNote.click()
        app.windows.firstMatch.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).click()

        let noteInput = app.textFields
            .matching(identifier: "pdf-thought-capture-popover").firstMatch
        XCTAssertTrue(noteInput.waitForExistence(timeout: 5), "Clicking a page should open its note draft.")
        noteInput.click()
        noteInput.typeText("Draft belongs to the background tab")

        firstTab.click()
        let closeSecond = app.buttons["Close \(second.lastPathComponent)"]
        XCTAssertTrue(closeSecond.waitForExistence(timeout: 5))
        closeSecond.click()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Closing the draft tab should ask before losing it.")
        let cancel = alert.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Closing the draft tab should ask before losing it.")
        cancel.click()

        XCTAssertTrue(secondTab.waitForExistence(timeout: 5), "Cancel must keep the requested tab open.")
        XCTAssertTrue(noteInput.waitForExistence(timeout: 5), "Cancel must keep the draft on its owning tab.")
        XCTAssertEqual(
            noteInput.value as? String,
            "Draft belongs to the background tab",
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

    private func open(_ url: URL, with applicationURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        _ = try await NSWorkspace.shared.open(
            [url], withApplicationAt: applicationURL, configuration: configuration
        )
    }
}
