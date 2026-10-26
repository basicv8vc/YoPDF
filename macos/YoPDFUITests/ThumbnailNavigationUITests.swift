import XCTest

@MainActor
final class ThumbnailNavigationUITests: XCTestCase {

    func testThumbnailArrowKeysNavigatePreviousAndNextPage() throws {
        let fixtureURL = try PDFFixtureFactory.writeTemporaryPDF(
            pageCount: 3,
            named: "thumbnail-arrows"
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

        guard app.windows.firstMatch.waitForExistence(timeout: 10),
              app.staticTexts[fixtureURL.lastPathComponent].waitForExistence(timeout: 10)
        else {
            XCTFail("The reader window did not open the thumbnail navigation test PDF.")
            return
        }

        let thumbnailsTab = app.buttons["Thumbnails"]
        guard thumbnailsTab.waitForExistence(timeout: 5) else {
            XCTFail("The Thumbnails sidebar tab did not appear.")
            return
        }
        thumbnailsTab.click()

        let firstPage = app.staticTexts["Page 1 of 3"]
        let secondPage = app.staticTexts["Page 2 of 3"]
        XCTAssertTrue(firstPage.waitForExistence(timeout: 5), "The reader should start on page 1.")

        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(secondPage.waitForExistence(timeout: 5), "Down Arrow should advance to page 2.")

        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(firstPage.waitForExistence(timeout: 5), "Up Arrow should return to page 1.")
    }
}
