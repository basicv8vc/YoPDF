import AppKit
import PDFKit
import XCTest

@MainActor
final class WorkspaceCloseUITests: XCTestCase {

    func testDirtyBackgroundTabSaveAffectsOnlyTheTarget() async throws {
        try await verifyDirtyBackgroundTabClose(.save)
    }

    func testDirtyBackgroundTabDiscardAffectsOnlyTheTarget() async throws {
        try await verifyDirtyBackgroundTabClose(.discard)
    }

    func testDirtyBackgroundTabCancelPreservesBothTabs() async throws {
        try await verifyDirtyBackgroundTabClose(.cancel)
    }

    func testWindowCloseSaveAllSavesEveryTab() async throws {
        try await verifyWindowClose(.saveAll)
    }

    func testWindowCloseDontSaveDiscardsEveryTab() async throws {
        try await verifyWindowClose(.discard)
    }

    func testWindowCloseCancelPreservesEveryTab() async throws {
        try await verifyWindowClose(.cancel)
    }

    func testQuitCancelPreservesDraftsAcrossMultipleWindowsAndTabs() async throws {
        let runID = UUID().uuidString
        let firstWindowFiles = try [makePDF("quit-first-a-\(runID)"), makePDF("quit-first-b-\(runID)")]
        let secondWindowFiles = try [makePDF("quit-second-a-\(runID)"), makePDF("quit-second-b-\(runID)")]
        let files = firstWindowFiles + secondWindowFiles
        defer { removeFixtures(files) }

        let applicationURL = try applicationURL()
        let app = try application(at: applicationURL)
        defer { app.terminate() }
        try await launch(app, at: applicationURL)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        try await open(firstWindowFiles, with: applicationURL, in: app)
        let firstDraft = "Draft in first window \(runID)"
        try createNoteDraft(firstDraft, on: firstWindowFiles[0], in: app)
        let firstDocumentEdit = "PDF edit in first window \(runID)"
        try createNoteDraft(firstDocumentEdit, on: firstWindowFiles[1], in: app)
        try commitDraftWithAutoSaveBlocked(for: firstWindowFiles[1], in: app)

        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(waitForWindowCount(2, in: app), "⌘N should create a second workspace window.")
        app.windows.element(boundBy: 1).click()
        try await open(secondWindowFiles, with: applicationURL, in: app)
        let secondDraft = "Draft in second window \(runID)"
        try createNoteDraft(secondDraft, on: secondWindowFiles[0], in: app)
        let secondDocumentEdit = "PDF edit in second window \(runID)"
        try createNoteDraft(secondDocumentEdit, on: secondWindowFiles[1], in: app)
        try commitDraftWithAutoSaveBlocked(for: secondWindowFiles[1], in: app)

        app.typeKey("q", modifierFlags: .command)
        let cancelQuit = app.sheets.firstMatch.buttons["Cancel"]
        XCTAssertTrue(cancelQuit.waitForExistence(timeout: 10), "Quit should ask before discarding drafts.")
        cancelQuit.click()

        XCTAssertTrue(bringToForeground(app, at: applicationURL))
        XCTAssertTrue(waitForWindowCount(2, in: app), "Cancel must keep both workspace windows open.")
        let expectedDrafts = [firstWindowFiles[0]: firstDraft, secondWindowFiles[0]: secondDraft]
        for (file, text) in expectedDrafts {
            assertDraft(text, remainsOn: file, in: app)
        }
        assertPDF(firstWindowFiles[1], contains: firstDocumentEdit, expected: false)
        assertPDF(secondWindowFiles[1], contains: secondDocumentEdit, expected: false)
        setWritable(firstWindowFiles[1])
        let firstWindow = selectTab(firstWindowFiles[1], in: app)
        firstWindow.buttons["Save"].click()
        assertPDF(firstWindowFiles[1], contains: firstDocumentEdit, expected: true)
        setWritable(secondWindowFiles[1])
        let secondWindow = selectTab(secondWindowFiles[1], in: app)
        secondWindow.buttons["Save"].click()
        assertPDF(secondWindowFiles[1], contains: secondDocumentEdit, expected: true)
        for (file, text) in expectedDrafts {
            saveDraft(text, on: file, in: app)
            assertPDF(file, contains: text, expected: true)
        }
    }

    // MARK: - UI setup and assertions

    private enum TabDisposition: Equatable {
        case save
        case discard
        case cancel

        var buttonTitle: String {
            switch self {
            case .save: "Save"
            case .discard: "Don’t Save"
            case .cancel: "Cancel"
            }
        }
    }

    private enum WorkspaceDisposition {
        case saveAll
        case discard
        case cancel

        var buttonTitle: String {
            switch self {
            case .saveAll: "Save All"
            case .discard: "Don’t Save"
            case .cancel: "Cancel"
            }
        }
    }

    private func verifyDirtyBackgroundTabClose(_ disposition: TabDisposition) async throws {
        let runID = UUID().uuidString
        let active = try makePDF("active-\(runID)")
        let target = try makePDF("target-\(runID)")
        let files = [active, target]
        defer { removeFixtures(files) }

        let applicationURL = try applicationURL()
        let app = try application(at: applicationURL)
        defer { app.terminate() }
        try await launch(app, at: applicationURL)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        try await open(files, with: applicationURL, in: app)

        let activeDraft = "Keep active draft \(runID)"
        let targetNote = "Target PDF edit \(runID)"
        try createNoteDraft(activeDraft, on: active, in: app)
        try createNoteDraft(targetNote, on: target, in: app)
        try commitDraftWithAutoSaveBlocked(for: target, in: app)
        assertPDF(target, contains: targetNote, expected: false)
        closeDirtyBackgroundTab(target, leaving: active, choosing: disposition, in: app)

        if disposition == .cancel {
            XCTAssertTrue(tab(for: target, in: app).waitForExistence(timeout: 5),
                          "Cancel must keep the requested background tab open.")
            let window = selectTab(target, in: app)
            setWritable(target)
            window.buttons["Save"].click()
        } else {
            XCTAssertFalse(tab(for: target, in: app).waitForExistence(timeout: 1),
                           "Save and Don’t Save should close only the requested tab.")
        }

        assertPDF(target, contains: targetNote, expected: disposition != .discard)
        assertDraft(activeDraft, remainsOn: active, in: app)
        saveDraft(activeDraft, on: active, in: app)
        assertPDF(active, contains: activeDraft, expected: true)
    }

    private func verifyWindowClose(_ disposition: WorkspaceDisposition) async throws {
        let runID = UUID().uuidString
        let files = try [makePDF("window-a-\(runID)"), makePDF("window-b-\(runID)")]
        defer { removeFixtures(files) }

        let applicationURL = try applicationURL()
        let app = try application(at: applicationURL)
        defer { app.terminate() }
        try await launch(app, at: applicationURL)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let documentNote = "Window PDF edit \(runID)"
        let noteDraft = "Window note draft \(runID)"
        try await prepareDirtyWorkspace(files, documentNote: documentNote, draftText: noteDraft,
                                        with: app, applicationURL: applicationURL)
        let choice = app.sheets.firstMatch.buttons[disposition.buttonTitle]
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "Window close should ask for a workspace decision.")
        if disposition != .discard {
            for file in files { setWritable(file) }
        }
        choice.click()

        switch disposition {
        case .saveAll:
            XCTAssertTrue(waitForWindowCount(0, in: app), "Save All should close the workspace window.")
            assertPDF(files[0], contains: documentNote, expected: true)
            assertPDF(files[1], contains: noteDraft, expected: true)
        case .discard:
            XCTAssertTrue(waitForWindowCount(0, in: app), "Don’t Save should close the workspace window.")
            assertPDF(files[0], contains: documentNote, expected: false)
            assertPDF(files[1], contains: noteDraft, expected: false)
        case .cancel:
            XCTAssertTrue(waitForWindowCount(1, in: app), "Cancel must leave the workspace open.")
            XCTAssertTrue(tab(for: files[0], in: app).exists)
            XCTAssertTrue(tab(for: files[1], in: app).exists)

            let firstWindow = selectTab(files[0], in: app)
            firstWindow.buttons["Save"].click()
            assertPDF(files[0], contains: documentNote, expected: true)
            assertDraft(noteDraft, remainsOn: files[1], in: app)
            let secondWindow = selectTab(files[1], in: app)
            submitNoteDraft(in: secondWindow)
            secondWindow.buttons["Save"].click()
            assertPDF(files[1], contains: noteDraft, expected: true)
        }
    }

    private func closeDirtyBackgroundTab(
        _ target: URL,
        leaving active: URL,
        choosing disposition: TabDisposition,
        in app: XCUIApplication
    ) {
        _ = selectTab(active, in: app)
        let close = app.buttons["Close \(target.lastPathComponent)"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.click()

        let documentPrompt = app.sheets.firstMatch
        let choice = documentPrompt.buttons[disposition.buttonTitle]
        XCTAssertTrue(choice.waitForExistence(timeout: 5),
                      "Closing the dirty target tab should ask how to resolve its PDF edit.")
        if disposition == .save { setWritable(target) }
        choice.click()
    }

    private func prepareDirtyWorkspace(
        _ files: [URL],
        documentNote: String,
        draftText: String,
        with app: XCUIApplication,
        applicationURL: URL
    ) async throws {
        try await open(files, with: applicationURL, in: app)
        for file in files {
            XCTAssertTrue(tab(for: file, in: app).waitForExistence(timeout: 10))
        }
        try createNoteDraft(documentNote, on: files[0], in: app)
        try createNoteDraft(draftText, on: files[1], in: app)

        let window = selectTab(files[0], in: app)
        let closeWindow = nativeCloseButton(in: window)
        XCTAssertTrue(closeWindow.waitForExistence(timeout: 5), "The native window close button should be available.")
        try commitDraftWithAutoSaveBlocked(for: files[0], in: app)
        closeWindow.click()
    }

    private func createNoteDraft(_ text: String, on file: URL, in app: XCUIApplication) throws {
        let window = selectTab(file, in: app)
        activate(app)
        let addNote = window.buttons.matching(identifier: "note.text.badge.plus").firstMatch
        XCTAssertTrue(addNote.waitForExistence(timeout: 5))
        addNote.click()
        XCTAssertTrue(window.buttons["Cancel Note"].waitForExistence(timeout: 5),
                      "Add Note should enter page placement mode.")
        XCTAssertTrue(window.isHittable, "The selected tab’s workspace window should be in front.")
        clickVisiblePDFPage(in: window)

        let input = noteInput(in: window)
        if !input.waitForExistence(timeout: 5) {
            XCTContext.runActivity(named: "PDF page placement accessibility snapshot") { activity in
                let attachment = XCTAttachment(string: app.debugDescription)
                attachment.name = "Reader hierarchy after clicking the PDF document view"
                activity.add(attachment)
            }
            XCTFail("Clicking the page should open its note composer.\n\(app.debugDescription)")
            return
        }
        input.click()
        input.typeText(text)
        XCTAssertEqual(input.value as? String, text, "Typing should update this tab’s note draft.")
    }

    private func submitNoteDraft(in window: XCUIElement) {
        let composerSubmit = window.buttons.matching(identifier: "pdf-thought-capture-popover")
            .matching(NSPredicate(format: "label == %@ OR label == %@", "Add", "Save")).firstMatch
        if composerSubmit.waitForExistence(timeout: 1) {
            composerSubmit.click()
            return
        }

        let reopen = window.buttons["Reopen the unsaved note draft"]
        XCTAssertTrue(reopen.waitForExistence(timeout: 5), "The active note draft should be reopenable.")
        reopen.click()
        XCTAssertTrue(composerSubmit.waitForExistence(timeout: 5), "The active note draft should have an Add button.")
        composerSubmit.click()
    }

    private func commitDraftWithAutoSaveBlocked(for file: URL, in app: XCUIApplication) throws {
        let window = selectTab(file, in: app)
        let directory = file.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

        submitNoteDraft(in: window)
        let okButton = app.sheets.firstMatch.buttons["OK"]
        let acknowledgement = try XCTUnwrap(
            okButton.waitForExistence(timeout: 5) ? okButton : nil,
            "The blocked automatic write should report a save failure before the dirty PDF is closed."
        )
        acknowledgement.click()
    }

    private func setWritable(_ file: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: file.deletingLastPathComponent().path
        )
    }

    private func assertDraft(_ expected: String, remainsOn file: URL, in app: XCUIApplication) {
        let window = selectTab(file, in: app)
        let input = noteInput(in: window)
        XCTAssertTrue(input.waitForExistence(timeout: 5), "The note draft should remain accessible.")
        XCTAssertEqual(input.value as? String, expected, "The other tab’s decision must preserve this draft.")
    }

    private func saveDraft(_ expected: String, on file: URL, in app: XCUIApplication) {
        let window = selectTab(file, in: app)
        let input = noteInput(in: window)
        XCTAssertTrue(input.waitForExistence(timeout: 5), "The note draft should remain accessible before cleanup.")
        XCTAssertEqual(input.value as? String, expected)
        submitNoteDraft(in: window)
        setWritable(file)
        window.buttons["Save"].click()
    }

    private func noteInput(in window: XCUIElement) -> XCUIElement {
        let identified = window.textFields.matching(identifier: "pdf-compact-note-input").firstMatch
        if identified.waitForExistence(timeout: 0.5) { return identified }

        let labelled = window.textFields.matching(NSPredicate(format: "label == %@", "Note contents")).firstMatch
        if labelled.waitForExistence(timeout: 0.5) { return labelled }

        let reopen = window.buttons["Reopen the unsaved note draft"]
        if reopen.waitForExistence(timeout: 1) { reopen.click() }
        return labelled
    }

    private func selectTab(_ file: URL, in app: XCUIApplication) -> XCUIElement {
        let tab = tab(for: file, in: app)
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "Expected tab \(file.lastPathComponent).")
        tab.click()
        let window = app.windows.containing(.button, identifier: tab.identifier).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "The selected tab should belong to a reader window.")
        return window
    }

    private func tab(for file: URL, in app: XCUIApplication) -> XCUIElement {
        app.buttons[file.lastPathComponent]
    }

    @discardableResult
    private func bringToForeground(_ app: XCUIApplication, at applicationURL: URL) -> Bool {
        guard let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier else {
            XCTFail("The built YoPDF app should have a bundle identifier.")
            return false
        }
        guard let process = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first(where: { $0.bundleURL?.standardizedFileURL == applicationURL.standardizedFileURL }) else {
            XCTFail("YoPDF should be running before UI interaction.")
            return false
        }

        _ = process.activate(options: [.activateAllWindows])
        app.activate()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTFail("YoPDF did not become the frontmost app before its workspace was queried.")
        return false
    }

    private func nativeCloseButton(in window: XCUIElement) -> XCUIElement {
        window.buttons.matching(NSPredicate(
            format: "identifier == %@ OR label == %@", "_XCUI:CloseWindow", "Close"
        ))
            .firstMatch
    }

    private func waitForWindowCount(_ expected: Int, in app: XCUIApplication) -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if app.windows.count == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    // MARK: - Fixtures

    private func makePDF(_ name: String) throws -> URL {
        try PDFFixtureFactory.writeTemporaryPDF(named: name)
    }

    private func removeFixtures(_ files: [URL]) {
        for file in files {
            let directory = file.deletingLastPathComponent()
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func assertPDF(
        _ file: URL,
        contains note: String,
        expected: Bool,
        filePath: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let document = PDFDocument(url: file) else {
            XCTFail("Expected a readable fixture at \(file.path)", file: filePath, line: line)
            return
        }
        let contents = (0..<document.pageCount).flatMap { pageIndex -> [String] in
            document.page(at: pageIndex)?.annotations.compactMap(\.contents) ?? []
        }
        XCTAssertEqual(contents.contains(note), expected,
                       "Unexpected note contents in \(file.lastPathComponent): \(contents)",
                       file: filePath, line: line)
    }

    // MARK: - App and PDF access

    private func applicationURL() throws -> URL {
        var directory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("YoPDF.app")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw NSError(domain: "WorkspaceCloseUITests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not find YoPDF.app beside the test runner."
        ])
    }

    private func application(at applicationURL: URL) throws -> XCUIApplication {
        guard let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier else {
            throw NSError(domain: "WorkspaceCloseUITests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The built YoPDF app should have a bundle identifier."
            ])
        }
        return XCUIApplication(bundleIdentifier: bundleIdentifier)
    }

    private func launch(_ app: XCUIApplication, at applicationURL: URL) async throws {
        if app.state != .notRunning {
            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        let process = try await NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration
        )
        XCTAssertEqual(process.bundleURL?.standardizedFileURL, applicationURL.standardizedFileURL,
                       "The UI test should launch the built YoPDF app, not another copy.")
        _ = process.activate(options: [.activateAllWindows])
        app.activate()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != process.processIdentifier {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, process.processIdentifier,
                       "The launched YoPDF process should become frontmost before UI queries begin.")
    }

    private func open(_ urls: [URL], with applicationURL: URL, in app: XCUIApplication) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        for url in urls {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "The PDF fixture must exist before opening: \(url.path)")
            _ = try await NSWorkspace.shared.open(
                [url], withApplicationAt: applicationURL, configuration: configuration
            )
            XCTAssertTrue(bringToForeground(app, at: applicationURL))
            XCTAssertTrue(tab(for: url, in: app).waitForExistence(timeout: 10),
                          "The opened PDF should have a workspace tab: \(url.path)")
        }
    }

    private func activate(_ app: XCUIApplication) {
        app.activate()
    }

    private func clickVisiblePDFPage(in window: XCUIElement) {
        let windowFrame = window.frame
        let documentView = window.scrollViews.allElementsBoundByIndex
            .filter {
                $0.frame.width > windowFrame.width * 0.55
                    && $0.frame.height > windowFrame.height * 0.55
            }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let documentView else {
            XCTFail("The selected reader should expose a visible PDF document scroll view.")
            return
        }
        let documentFrame = documentView.frame
        let target = CGPoint(x: documentFrame.midX, y: documentFrame.minY + documentFrame.height * 0.35)
        window.coordinate(withNormalizedOffset: CGVector(
            dx: (target.x - windowFrame.minX) / windowFrame.width,
            dy: (target.y - windowFrame.minY) / windowFrame.height
        )).click()
    }
}
