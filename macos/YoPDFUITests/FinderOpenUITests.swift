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

        // `XCUIApplication.open(_:)` launches the app through LaunchServices
        // with a document, exercising the same open-document path as Finder's
        // Open With command without first starting an empty reader.
        app.open(first)
        XCTAssertTrue(app.staticTexts[first.lastPathComponent].waitForExistence(timeout: 15),
                      "A cold Finder launch must load the requested PDF.")
        assertReaderWindows([first], in: app)
    }

    func testFinderBatchOpenIsRejectedWithoutReplacingTheOpenDocument() async throws {
        let runID = UUID().uuidString
        let first = try PDFFixtureFactory.writeTemporaryPDF(named: "finder-batch-first-\(runID)")
        let second = try PDFFixtureFactory.writeTemporaryPDF(named: "finder-batch-second-\(runID)")
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }

        let applicationURL = try applicationURL()
        let app = XCUIApplication(url: applicationURL)
        defer { app.terminate() }
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        try await open([first], with: applicationURL)
        XCTAssertTrue(app.staticTexts[first.lastPathComponent].waitForExistence(timeout: 10))
        assertReaderWindows([first], in: app)

        // One LaunchServices action with two files is a batch. YoPDF currently
        // declines multi-file batches, so it must leave the current document
        // alone rather than opening only one item or keeping only the last one.
        try await open(
            [first, second],
            with: applicationURL,
            allowLaunchServicesFailure: true
        )
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(app.staticTexts[first.lastPathComponent].exists)
        XCTAssertFalse(app.staticTexts[second.lastPathComponent].exists,
                       "A rejected batch must not open any of its PDFs.")
        assertReaderWindows([first], in: app)
    }

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
        var remainingTitles = Set([first, second, third, fourth].map(\.lastPathComponent))
        for _ in 0..<4 {
            guard let closedTitle = closeActiveReaderWindow(in: app) else { break }
            XCTAssertTrue(remainingTitles.remove(closedTitle) != nil,
                          "⌘W closed unexpected window \(closedTitle).")
            let remainingDocuments = [first, second, third, fourth].filter {
                remainingTitles.contains($0.lastPathComponent)
            }
            assertReaderWindows(remainingDocuments, in: app)
        }
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
        with applicationURL: URL,
        allowLaunchServicesFailure: Bool = false
    ) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        do {
            _ = try await NSWorkspace.shared.open(
                urls, withApplicationAt: applicationURL, configuration: configuration
            )
        } catch {
            guard allowLaunchServicesFailure else { throw error }
        }
    }

    private func closeActiveReaderWindow(in app: XCUIApplication) -> String? {
        app.activate()
        let before = Set(app.windows.allElementsBoundByIndex.map(\.title))
        XCTAssertFalse(before.isEmpty, "Expected a reader window to close.")

        app.typeKey("w", modifierFlags: .command)

        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let after = Set(app.windows.allElementsBoundByIndex.map(\.title))
            if after.count == before.count - 1 {
                let closed = before.subtracting(after)
                XCTAssertEqual(closed.count, 1,
                               "⌘W must close exactly one window. Before: \(before), after: \(after).")
                return closed.first
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("⌘W did not close a reader window. Windows: \(before).")
        return nil
    }

    private func assertReaderWindows(_ documents: [URL], in app: XCUIApplication) {
        let expectedTitles = Set(documents.map(\.lastPathComponent))
        let windowTitles = app.windows.allElementsBoundByIndex.map(\.title)
        let matchingTitles = windowTitles.filter(expectedTitles.contains)
        XCTAssertEqual(Set(matchingTitles), expectedTitles)
        XCTAssertEqual(matchingTitles.count, expectedTitles.count,
                       "Each requested PDF should appear in exactly one reader window.")
        XCTAssertEqual(windowTitles.count, expectedTitles.count,
                       "Unexpected reader window(s): \(windowTitles).")
    }

}
