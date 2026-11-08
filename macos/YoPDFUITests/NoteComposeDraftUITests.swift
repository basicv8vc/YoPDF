import XCTest

/// End-to-end coverage for the compose draft prompt.
///
/// Clicking another note while a composer holds unsaved text asks "Save this
/// note first?". Answering "Save Note" must write the draft AND open the note
/// that was clicked; the same question must not come back on the next click.
/// These tests need an interactive Aqua session (`scripts/test-ui.sh`).
@MainActor
final class NoteComposeDraftUITests: XCTestCase {

    func testSavingTheDraftFromTheComposePromptOpensTheClickedNote() throws {
        let fixtureURL = try PDFFixtureFactory.writeTemporaryPDF(
            pageCount: 1,
            named: "compose-draft",
            text: { _ in "A page used to place two notes" }
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
            return XCTFail("The reader did not open the fixture PDF.")
        }

        let window = app.windows.firstMatch
        let savedNotePoint = CGVector(dx: 0.5, dy: 0.32)
        let draftPoint = CGVector(dx: 0.5, dy: 0.55)

        // 1. A note that is really in the document, so it can be clicked later.
        startNewNote(in: app)
        clickPage(window, at: savedNotePoint)
        let firstInput = try noteInput(in: app)
        firstInput.click()
        firstInput.typeText("Saved note")
        submitNote(in: app)
        XCTAssertTrue(waitForComposerToDisappear(in: app), "saving closes the composer")

        // 2. A second composer left with unsaved text.
        startNewNote(in: app)
        clickPage(window, at: draftPoint)
        let draftInput = try noteInput(in: app)
        draftInput.click()
        draftInput.typeText("Draft that is not in the document")

        // 3. Clicking the saved note must ask about the draft first.
        clickPage(window, at: savedNotePoint)
        let prompt = app.sheets.firstMatch
        guard prompt.waitForExistence(timeout: 5),
              prompt.buttons["Save Note"].waitForExistence(timeout: 5)
        else {
            return XCTFail("Clicking another note while a draft is open should ask about the draft.")
        }
        prompt.buttons["Save Note"].click()
        XCTAssertTrue(waitForPromptToDisappear(in: app), "Save Note dismisses the prompt")

        // 4. The saved draft is gone: clicking the note again must open it,
        //    not show "Save this note first?" a second time.
        clickPage(window, at: savedNotePoint)
        if app.sheets.firstMatch.waitForExistence(timeout: 3) {
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = "Reader hierarchy after the draft was saved"
            add(attachment)
            return XCTFail("The saved draft must not be reported as unsaved work again.")
        }
    }

    // MARK: - Helpers

    private func startNewNote(in app: XCUIApplication) {
        let addNote = app.buttons["Add Note"]
        let cancelPlacement = app.buttons["Cancel Note"]
        if addNote.waitForExistence(timeout: 5) {
            addNote.click()
        } else {
            XCTAssertTrue(
                cancelPlacement.waitForExistence(timeout: 5),
                "The Add Note button should be available"
            )
        }
    }

    private func clickPage(_ window: XCUIElement, at offset: CGVector) {
        let windowFrame = window.frame
        let documentView = window.scrollViews.allElementsBoundByIndex
            .filter {
                $0.frame.width > windowFrame.width * 0.55
                    && $0.frame.height > windowFrame.height * 0.55
            }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let documentView else {
            return XCTFail("The reader should expose its visible PDF document scroll view.")
        }
        let documentFrame = documentView.frame
        let target = CGPoint(
            x: documentFrame.minX + documentFrame.width * offset.dx,
            y: documentFrame.minY + documentFrame.height * offset.dy
        )
        window.coordinate(withNormalizedOffset: CGVector(
            dx: (target.x - windowFrame.minX) / windowFrame.width,
            dy: (target.y - windowFrame.minY) / windowFrame.height
        )).click()
    }

    private func noteInput(in app: XCUIApplication) throws -> XCUIElement {
        let composer = app.descendants(matching: .any)
            .matching(identifier: "pdf-thought-capture-popover").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "The note composer did not open.")
        let input = app.textFields.matching(identifier: "pdf-compact-note-input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5), "The note body field did not appear.")
        return input
    }

    private func submitNote(in app: XCUIApplication) {
        let submit = app.buttons.matching(identifier: "pdf-compact-note-submit").firstMatch
        XCTAssertTrue(submit.waitForExistence(timeout: 5), "The note submit button did not appear.")
        submit.click()
    }

    private func waitForComposerToDisappear(in app: XCUIApplication) -> Bool {
        let composer = app.descendants(matching: .any)
            .matching(identifier: "pdf-thought-capture-popover").firstMatch
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !composer.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !composer.exists
    }

    private func waitForPromptToDisappear(in app: XCUIApplication) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !app.sheets.firstMatch.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !app.sheets.firstMatch.exists
    }
}
