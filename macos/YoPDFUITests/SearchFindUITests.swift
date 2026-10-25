import XCTest
import PDFKit

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

    func testOutlineArrowMonitorYieldsToSearchFieldCaret() throws {
        let fixtureURL = try writeOutlinePDF()
        defer {
            try? FileManager.default.removeItem(at: fixtureURL.deletingLastPathComponent())
        }

        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["YOPDF_SCREENSHOT_PDF"] = fixtureURL.path
        app.launch()
        defer { app.terminate() }
        app.activate()

        guard app.windows.firstMatch.waitForExistence(timeout: 10),
              app.staticTexts[fixtureURL.lastPathComponent].waitForExistence(timeout: 10)
        else {
            XCTFail("The reader window did not open the outline test PDF.")
            return
        }

        let outlineTab = app.buttons["Outline"]
        guard outlineTab.waitForExistence(timeout: 5) else {
            XCTFail("The Outline sidebar tab did not appear.")
            return
        }
        outlineTab.click()

        let chapter = app.buttons["Chapter A"]
        let child = app.buttons["Section A.1"]
        guard chapter.waitForExistence(timeout: 5), child.waitForExistence(timeout: 5) else {
            XCTFail("The test PDF outline was not displayed.")
            return
        }
        chapter.click()

        app.typeKey("f", modifierFlags: .command)
        let searchField = app.textFields["pdf-search-field"]
        guard searchField.waitForExistence(timeout: 5) else {
            XCTFail("⌘F did not open the search field.")
            return
        }
        searchField.typeText("needle")

        let summary = app.staticTexts["pdf-search-result-summary"]
        wait(for: summary, toHaveValue: "Result 1 of 3")

        searchField.typeKey(.leftArrow, modifierFlags: [])
        searchField.typeText("X")
        XCTAssertEqual(searchField.value as? String, "needlXe")

        searchField.typeKey(.rightArrow, modifierFlags: [])
        searchField.typeText("Y")
        XCTAssertEqual(searchField.value as? String, "needlXeY")
        XCTAssertTrue(child.exists, "Search caret movement must not collapse the selected outline section.")
    }

    private func writeOutlinePDF() throws -> URL {
        let url = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 3, named: "outline-search") {
            "needle on page \($0 + 1)"
        }
        let document = try XCTUnwrap(PDFDocument(url: url))
        let root = PDFOutline()

        let chapter = PDFOutline()
        chapter.label = "Chapter A"
        chapter.isOpen = true
        chapter.destination = PDFDestination(
            page: try XCTUnwrap(document.page(at: 0)),
            at: CGPoint(x: 72, y: 700)
        )

        let child = PDFOutline()
        child.label = "Section A.1"
        child.destination = PDFDestination(
            page: try XCTUnwrap(document.page(at: 1)),
            at: CGPoint(x: 72, y: 700)
        )
        chapter.insertChild(child, at: 0)
        root.insertChild(chapter, at: 0)
        document.outlineRoot = root

        guard document.write(to: url) else {
            throw NSError(domain: "SearchFindUITests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not write the outline test PDF."
            ])
        }
        return url
    }

    private func wait(for element: XCUIElement, toHaveValue value: String) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
}
