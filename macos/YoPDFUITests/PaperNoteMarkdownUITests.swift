//
//  PaperNoteMarkdownUITests.swift
//  YoPDFUITests
//
//  Created for Task P0-C-C: Heterogeneous Markdown Pane Integration.
//  Apache-2.0 Open Source License.
//

import XCTest

@MainActor
final class PaperNoteMarkdownUITests: XCTestCase {

    func testOpenPaperNoteSplitInsertCitationEditAndSave() throws {
        let fixtureURL = try PDFFixtureFactory.writeTemporaryPDF(
            pageCount: 5,
            named: "paper-note-smoke",
            text: { pageIndex in
                "Research Paper Page \(pageIndex + 1)\nKey experimental observation on page \(pageIndex + 1)."
            }
        )
        let expectedNoteURL = fixtureURL
            .deletingLastPathComponent()
            .appendingPathComponent("paper-note-smoke.notes.md")
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
              app.buttons[fixtureURL.lastPathComponent].waitForExistence(timeout: 20)
        else {
            return XCTFail("The reader window did not open the smoke test PDF.")
        }

        // Navigate PDF to page 3 before creating/citing in the paper note.
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeKey(.downArrow, modifierFlags: .command)
        XCTAssertTrue(
            app.staticTexts["Page 3 of 5"].waitForExistence(timeout: 5),
            "PDF pane should navigate to Page 3 of 5."
        )

        let openNoteButton = app.buttons["pdf-open-paper-note-button"]
        XCTAssertTrue(openNoteButton.waitForExistence(timeout: 5), "Open Paper Note toolbar button should exist.")
        XCTAssertTrue(openNoteButton.isEnabled, "Open Paper Note toolbar button should be enabled for a saved PDF.")

        // 1. Open/create the sidecar paper note in a right split pane.
        openNoteButton.click()

        let verticalDivider = app.buttons["Vertical split divider"]
        XCTAssertTrue(
            verticalDivider.waitForExistence(timeout: 10),
            "Opening Paper Note should create a left/right split layout."
        )

        let insertCitationButton = app.buttons["markdown-insert-citation-button"]
        XCTAssertTrue(
            insertCitationButton.waitForExistence(timeout: 5),
            "Focusing the new Markdown pane should switch to the Markdown toolbar."
        )
        XCTAssertTrue(insertCitationButton.isEnabled, "Insert Citation should be enabled with companion PDF.")
        XCTAssertTrue(
            app.staticTexts["paper-note-smoke.notes.md"].waitForExistence(timeout: 5),
            "Markdown pane header should display paper-note-smoke.notes.md."
        )

        // Verify the sidecar .notes.md file was created on disk.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: expectedNoteURL.path),
            "Expected sidecar Markdown file to be created at \(expectedNoteURL.path)."
        )

        // 2. Insert a portable CommonMark citation for page 3 via the Markdown toolbar.
        insertCitationButton.click()

        // 3. Type additional note text into the Markdown editor, verify Undo/Redo, and save.
        let editorTextView = app.textViews.firstMatch
        XCTAssertTrue(editorTextView.waitForExistence(timeout: 5), "Markdown editor text view should exist.")

        let editorValuePredicate = NSPredicate { element, _ in
            guard let text = (element as? XCUIElement)?.value as? String else { return false }
            return text.contains("./paper-note-smoke.pdf#page=3")
        }
        let citationExpectation = XCTNSPredicateExpectation(predicate: editorValuePredicate, object: editorTextView)
        XCTAssertEqual(
            XCTWaiter.wait(for: [citationExpectation], timeout: 5),
            .completed,
            "Markdown editor should display inserted page 3 citation."
        )

        editorTextView.click()
        editorTextView.typeText("\n- Verified UI note persistence.")

        let typedPredicate = NSPredicate { element, _ in
            guard let text = (element as? XCUIElement)?.value as? String else { return false }
            return text.contains("Verified UI note persistence.")
        }
        let typedExpectation = XCTNSPredicateExpectation(predicate: typedPredicate, object: editorTextView)
        XCTAssertEqual(
            XCTWaiter.wait(for: [typedExpectation], timeout: 5),
            .completed,
            "Markdown editor should contain typed note text."
        )

        // Exercise isolated Undo/Redo on the active Markdown editor.
        app.typeKey("z", modifierFlags: .command)
        let undonePredicate = NSPredicate { element, _ in
            guard let text = (element as? XCUIElement)?.value as? String else { return false }
            return !text.contains("Verified UI note persistence.")
        }
        let undoneExpectation = XCTNSPredicateExpectation(predicate: undonePredicate, object: editorTextView)
        XCTAssertEqual(
            XCTWaiter.wait(for: [undoneExpectation], timeout: 5),
            .completed,
            "Cmd+Z should undo the typed Markdown edit."
        )

        app.typeKey("z", modifierFlags: [.command, .shift])
        let redoneExpectation = XCTNSPredicateExpectation(predicate: typedPredicate, object: editorTextView)
        XCTAssertEqual(
            XCTWaiter.wait(for: [redoneExpectation], timeout: 5),
            .completed,
            "Shift+Cmd+Z should redo the undone Markdown edit."
        )

        app.typeKey("s", modifierFlags: .command)

        let savedDeadline = Date().addingTimeInterval(5)
        var savedText = ""
        while Date() < savedDeadline {
            if let content = try? String(contentsOf: expectedNoteURL, encoding: .utf8) {
                savedText = content
                if content.contains("#page=3"),
                   content.contains("Verified UI note persistence.") {
                    break
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTAssertTrue(
            savedText.contains("./paper-note-smoke.pdf#page=3"),
            "Saved Markdown file should contain portable page 3 citation, got:\n\(savedText)"
        )
        XCTAssertTrue(
            savedText.contains("Verified UI note persistence."),
            "Saved Markdown file should contain typed note text, got:\n\(savedText)"
        )

        // 4. Close the Markdown pane cleanly once saved and verify single-pane PDF restoration.
        let closePaneButton = app.buttons["pdf-close-pane-button"]
        XCTAssertTrue(closePaneButton.waitForExistence(timeout: 5))
        XCTAssertTrue(closePaneButton.isEnabled)
        closePaneButton.click()

        let disabledPredicate = NSPredicate(format: "isEnabled == false")
        let expectation = XCTNSPredicateExpectation(predicate: disabledPredicate, object: closePaneButton)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
        XCTAssertTrue(
            app.buttons["pdf-open-paper-note-button"].waitForExistence(timeout: 5),
            "Closing the Markdown pane should restore the PDF toolbar."
        )
    }
}
