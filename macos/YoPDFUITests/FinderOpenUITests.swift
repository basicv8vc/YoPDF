import AppKit
import XCTest

@MainActor
final class FinderOpenUITests: XCTestCase {

    func testFinderOpenFromColdLaunchThenExistingAndClosedWindows() async throws {
        let first = try PDFFixtureFactory.writeTemporaryPDF(named: "finder-first")
        let second = try PDFFixtureFactory.writeTemporaryPDF(named: "finder-second")
        let corrupt = try PDFFixtureFactory.writeTemporaryFile(
            named: "finder-corrupt.pdf", contents: Data("Not a PDF".utf8)
        )
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: corrupt.deletingLastPathComponent())
        }

        let applicationURL = try applicationURL()
        let app = XCUIApplication(url: applicationURL)
        defer { app.terminate() }
        app.terminate()

        // LaunchServices sends the same open-document event as Finder's Open
        // With command. Do not use the screenshot hook or the in-app Open panel.
        try await open(first, with: applicationURL)
        XCTAssertTrue(app.staticTexts[first.lastPathComponent].waitForExistence(timeout: 10),
                      "A cold Finder launch must load the requested PDF, not just start the app.")

        try await open(second, with: applicationURL)
        XCTAssertTrue(app.staticTexts[second.lastPathComponent].waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, 1, "A warm file open should reuse the reader.")

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.waitForNonExistence(timeout: 5))
        try await open(first, with: applicationURL)
        XCTAssertTrue(app.staticTexts[first.lastPathComponent].waitForExistence(timeout: 10),
                      "Finder must create a reader after every reader window was closed.")
        XCTAssertEqual(app.windows.count, 1)

        try await open(corrupt, with: applicationURL)
        XCTAssertTrue(app.staticTexts["Couldn’t open this document"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[first.lastPathComponent].exists,
                      "An unreadable Finder file must leave the current PDF open.")
        app.typeKey(.return, modifierFlags: [])
        try await open(second, with: applicationURL)
        XCTAssertTrue(app.staticTexts[second.lastPathComponent].waitForExistence(timeout: 10),
                      "A failed open must release the request slot for the next Finder event.")
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

    private func open(_ url: URL, with applicationURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        _ = try await NSWorkspace.shared.open(
            [url], withApplicationAt: applicationURL, configuration: configuration
        )
    }
}
