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
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["YOPDF_SCREENSHOT_PDF"] = fixtureURL.path
        app.launch()
        defer { app.terminate() }
        app.activate()

        guard app.windows.firstMatch.waitForExistence(timeout: 10) else {
            XCTFail("The reader window did not open.")
            return
        }
        guard app.staticTexts[fixtureURL.lastPathComponent].waitForExistence(timeout: 10) else {
            XCTFail("The test PDF did not load in the reader.")
            return
        }

        app.typeKey("f", modifierFlags: .command)
        let searchField = app.textFields["pdf-search-field"]
        guard searchField.waitForExistence(timeout: 5) else {
            XCTFail("⌘F did not open the search field.")
            return
        }
        searchField.typeText("needle")

        let summary = app.staticTexts["pdf-search-result-summary"]
        wait(for: summary, toHaveValue: "Result 1 of 4")

        app.typeKey("g", modifierFlags: .command)
        wait(for: summary, toHaveValue: "Result 2 of 4")

        app.typeKey("f", modifierFlags: .command)
        wait(for: summary, toHaveValue: "Result 2 of 4")

        // Replacing the query in one input proves ⌘F selected the existing text.
        searchField.typeText("replacement")
        XCTAssertEqual(searchField.value as? String, "replacement")
    }

    private func wait(for element: XCUIElement, toHaveValue value: String) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
}
