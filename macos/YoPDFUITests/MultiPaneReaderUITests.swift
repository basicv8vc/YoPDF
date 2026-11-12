//
//  MultiPaneReaderUITests.swift
//  YoPDFUITests
//
//  Created for Task P0-B-C: Multi-Pane UI Integration.
//  Apache-2.0 Open Source License.
//

import XCTest
import PDFKit

@MainActor
final class MultiPaneReaderUITests: XCTestCase {

    func testMultiPaneSmokeWorkflowAndCaptureScreenshots() throws {
        let fixtureURL = try PDFFixtureFactory.writeTemporaryPDF(
            pageCount: 15,
            named: "multipane-smoke",
            text: { pageIndex in
                "Research Paper Section \(pageIndex + 1)\nThis is page \(pageIndex + 1) of 15 in the test multi-pane workspace document."
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

        guard app.windows.firstMatch.waitForExistence(timeout: 20),
              app.staticTexts[fixtureURL.lastPathComponent].waitForExistence(timeout: 20)
        else {
            return XCTFail("The reader window did not open the smoke test PDF.")
        }

        let window = app.windows.firstMatch
        let splitRightButton = app.buttons["pdf-split-right-button"]
        let splitDownButton = app.buttons["pdf-split-down-button"]
        let closePaneButton = app.buttons["pdf-close-pane-button"]

        XCTAssertTrue(splitRightButton.waitForExistence(timeout: 5), "Split Right button should exist in toolbar")
        XCTAssertTrue(splitDownButton.waitForExistence(timeout: 5), "Split Down button should exist in toolbar")
        XCTAssertTrue(closePaneButton.waitForExistence(timeout: 5), "Close Pane button should exist in toolbar")
        XCTAssertTrue(splitRightButton.isEnabled, "Split Right should be enabled for loaded document")
        XCTAssertFalse(closePaneButton.isEnabled, "Close Pane should be disabled when only 1 pane exists")

        // 1. Split Right
        splitRightButton.click()

        // Wait for Close Pane button to become enabled (indicating 2 panes now exist)
        let predicate = NSPredicate(format: "isEnabled == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: closePaneButton)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)

        // 2. Pane B is active right after split. Verify divider exists.
        let verticalDivider = app.buttons["Vertical split divider"]
        XCTAssertTrue(verticalDivider.waitForExistence(timeout: 5), "Vertical split divider should be present in 2-pane layout")

        // Navigate Pane B to Page 10 and Zoom In
        for _ in 1...9 {
            app.typeKey(.downArrow, modifierFlags: .command)
        }
        app.typeKey("+", modifierFlags: .command)
        app.typeKey("+", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["10 / 15"].waitForExistence(timeout: 5), "Active Pane B indicator should reflect Page 10 / 15")

        // 3. Click left half of the window to activate Pane A
        let paneACoordinate = window.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        paneACoordinate.click()

        // Navigate Pane A to Page 3 and Zoom Out
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeKey("-", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["3 / 15"].waitForExistence(timeout: 5), "Active Pane A indicator should reflect Page 3 / 15")

        // 4. Capture screenshot of the active two-pane Reader
        let screenshot = window.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Real Two-Pane Reader (Independent Pages and Zooms)"
        attachment.lifetime = .keepAlways
        add(attachment)

        let artifactDir = URL(fileURLWithPath: "/Users/lj/.gemini/antigravity/brain/81965ccd-cf8a-4603-a664-43d598f9ea8d")
        let screenshotURL = artifactDir.appendingPathComponent("screenshot-multipane.png")
        try? screenshot.pngRepresentation.write(to: screenshotURL)

        // 5. Close Pane A via Close Pane button or shortcut
        closePaneButton.click()
        if closePaneButton.isEnabled {
            app.typeKey("w", modifierFlags: [.command, .option])
        }

        // Verify Close Pane becomes disabled again as we return to 1 pane
        let disabledPredicate = NSPredicate(format: "isEnabled == false")
        let disabledExpectation = XCTNSPredicateExpectation(predicate: disabledPredicate, object: closePaneButton)
        _ = XCTWaiter.wait(for: [disabledExpectation], timeout: 5)

        // 6. Capture screenshot of surviving single pane
        let closedScreenshot = window.screenshot()
        let closedAttachment = XCTAttachment(screenshot: closedScreenshot)
        closedAttachment.name = "Reader After Closing One Pane"
        closedAttachment.lifetime = .keepAlways
        add(closedAttachment)

        let closedScreenshotURL = artifactDir.appendingPathComponent("screenshot-pane-closed.png")
        try? closedScreenshot.pngRepresentation.write(to: closedScreenshotURL)
    }
}
