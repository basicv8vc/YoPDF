import AppKit
import XCTest

@MainActor
final class FinderOpenUITests: XCTestCase {

    func testFinderOpenIntoExistingThenRapidAndClosedWindows() async throws {
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
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "--yopdf-test-reader-request-delay-ms=700"
        ]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // LaunchServices sends the same open-document event as Finder's Open
        // With command. Do not use the screenshot hook or the in-app Open panel.
        try await open([first], with: applicationURL)
        XCTAssertTrue(app.staticTexts[first.lastPathComponent].waitForExistence(timeout: 10),
                      "Finder must load the requested PDF into an empty reader.")
        assertReaderWindows([first], in: app)

        try await open([second], with: applicationURL)
        XCTAssertTrue(app.staticTexts[second.lastPathComponent].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[first.lastPathComponent].exists,
                      "Opening another PDF must leave the first reader open.")
        assertReaderWindows([first, second], in: app)

        // Hold the new WindowGroup scene before it consumes its UUID request.
        // A second Finder event must be routed to an available reader, not into
        // the still-empty scene that is about to load the first URL.
        try await open([third], with: applicationURL)
        try await open([fourth], with: applicationURL)
        XCTAssertTrue(app.staticTexts[third.lastPathComponent].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[fourth.lastPathComponent].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[first.lastPathComponent].exists)
        XCTAssertTrue(app.staticTexts[second.lastPathComponent].exists)
        assertReaderWindows([first, second, third, fourth], in: app)
        closeReaderWindow(titled: fourth.lastPathComponent, in: app)
        closeReaderWindow(titled: third.lastPathComponent, in: app)
        assertReaderWindows([first, second], in: app)
        XCTAssertTrue(app.staticTexts[first.lastPathComponent].exists)
        XCTAssertTrue(app.staticTexts[second.lastPathComponent].exists)
        closeReaderWindow(titled: second.lastPathComponent, in: app)
        assertReaderWindows([first], in: app)
        XCTAssertTrue(app.staticTexts[first.lastPathComponent].exists)
        closeReaderWindow(titled: first.lastPathComponent, in: app)
        assertReaderWindows([], in: app)
        try await open([first], with: applicationURL)
        XCTAssertTrue(app.staticTexts[first.lastPathComponent].waitForExistence(timeout: 10),
                      "Finder must create a reader after every reader window was closed.")
        assertReaderWindows([first], in: app)

        try await open([corrupt], with: applicationURL)
        XCTAssertTrue(app.staticTexts["Couldn’t open this document"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[first.lastPathComponent].exists,
                      "An unreadable Finder file must leave the current PDF open.")
        app.typeKey(.return, modifierFlags: [])
        try await open([second], with: applicationURL)
        XCTAssertTrue(app.staticTexts[second.lastPathComponent].waitForExistence(timeout: 10),
                      "A failed open must release the request slot for the next Finder event.")
        assertReaderWindows([first, second], in: app)
    }

    private func applicationURL() throws -> URL {
        // The UI test bundle lives inside the runner app beside YoPDF.app in
        // BUILT_PRODUCTS_DIR. Resolve that exact build, not a LaunchServices
        // bundle-ID lookup that could choose another installed YoPDF.
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

    private func open(
        _ urls: [URL],
        with applicationURL: URL
    ) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        _ = try await NSWorkspace.shared.open(
            urls, withApplicationAt: applicationURL, configuration: configuration
        )
    }

    private func closeReaderWindow(titled title: String, in app: XCUIApplication) {
        let window = app.windows.matching(NSPredicate(format: "title == %@", title)).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "Expected reader window \(title).")
        window.click()
        app.typeKey("w", modifierFlags: .command)
    }

    private func assertReaderWindows(_ documents: [URL], in app: XCUIApplication) {
        let expectedTitles = Set(documents.map(\.lastPathComponent))
        let matchingTitles = app.windows.allElementsBoundByIndex
            .map(\.title)
            .filter(expectedTitles.contains)
        XCTAssertEqual(Set(matchingTitles), expectedTitles)
        XCTAssertEqual(matchingTitles.count, expectedTitles.count,
                       "Each requested PDF should appear in exactly one reader window.")
    }

}
