import XCTest

@MainActor
final class SearchFindUITests: XCTestCase {

    func testRepeatedCommandFSelectsQueryWithoutMovingCurrentResult() throws {
        let fixtureURL = try PDFFixtureFactory.writeTemporaryPDF(
            pageCount: 3,
            named: "repeat-find",
            text: { page in
                page == 0 ? "needle alpha needle omega" : "needle on page \(page + 1)"
            }
        )
        defer {
            try? FileManager.default.removeItem(at: fixtureURL.deletingLastPathComponent())
        }

        let app = XCUIApplication()
        app.launchEnvironment["YOPDF_SCREENSHOT_PDF"] = fixtureURL.path
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts[fixtureURL.lastPathComponent].waitForExistence(timeout: 10))

        app.typeKey("f", modifierFlags: .command)
        let searchField = app.textFields["pdf-search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.typeText("needle")

        let summary = app.staticTexts["pdf-search-result-summary"]
        wait(for: summary, toHaveLabel: "Result 1 of 4")

        app.typeKey("g", modifierFlags: .command)
        wait(for: summary, toHaveLabel: "Result 2 of 4")

        app.typeKey("f", modifierFlags: .command)
        wait(for: summary, toHaveLabel: "Result 2 of 4")

        // Replacing the query in one input proves ⌘F selected the existing text.
        searchField.typeText("replacement")
        XCTAssertEqual(searchField.value as? String, "replacement")
    }

    private func wait(for element: XCUIElement, toHaveLabel label: String) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
}
