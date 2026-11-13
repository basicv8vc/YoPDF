import Combine
import Foundation
import XCTest
@testable import YoPDFCore

@MainActor
final class MarkdownResourceSessionTests: XCTestCase {

    private var directory: TemporaryDirectory!
    private var cancellables = Set<AnyCancellable>()

    override func setUpWithError() throws {
        directory = try TemporaryDirectory("markdown-resource")
    }

    override func tearDown() {
        cancellables.removeAll()
        directory?.remove()
        directory = nil
        super.tearDown()
    }

    private func makeMarkdownFile(_ name: String = "note.md", content: String) throws -> URL {
        try directory.write(name, Data(content.utf8))
    }

    // MARK: - Create, Open, Edit, Save, Reopen

    func testCreateEditSaveAndReopenRoundTrip() throws {
        let noteURL = directory.url.appendingPathComponent("paper.notes.md")
        let spy = SecurityScopeSpy()
        let session = MarkdownResourceSession(access: spy)

        XCTAssertTrue(session.create(at: noteURL, initialContent: "# Initial Heading\n"))
        XCTAssertTrue(session.isLoaded)
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertEqual(session.fileURL, noteURL)
        XCTAssertEqual(session.title, "paper.notes")
        XCTAssertEqual(session.detectedLineEnding, .lf)
        let revisionAfterCreate = session.editRevision

        session.updateContent("# Initial Heading\n\n- Key insight from section 2.\n")
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertEqual(session.editRevision, revisionAfterCreate + 1)

        XCTAssertEqual(session.save(), .saved)
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertEqual(session.editRevision, revisionAfterCreate + 2)
        session.close()

        let reopened = MarkdownResourceSession(access: spy)
        XCTAssertTrue(reopened.open(url: noteURL))
        XCTAssertEqual(reopened.content, "# Initial Heading\n\n- Key insight from section 2.\n")
        XCTAssertFalse(reopened.hasUnsavedChanges)
        reopened.close()
    }

    func testOpenEmptyMarkdownFileAndMarkdownExtension() throws {
        let emptyURL = try makeMarkdownFile("empty.markdown", content: "")
        let session = MarkdownResourceSession(access: SecurityScopeSpy())

        XCTAssertTrue(session.open(url: emptyURL))
        XCTAssertEqual(session.content, "")
        XCTAssertNil(session.detectedLineEnding)
        XCTAssertFalse(session.hasUnsavedChanges)

        session.updateContent("First line")
        XCTAssertEqual(session.save(), .saved)
        XCTAssertEqual(try String(contentsOf: emptyURL, encoding: .utf8), "First line")
        session.close()
    }

    func testNoOpEditAndRevertingToSavedBaselineClearsDirtyFlag() throws {
        let url = try makeMarkdownFile(content: "Original")
        let session = MarkdownResourceSession(access: SecurityScopeSpy())
        session.isAutoSaveEnabled = false
        XCTAssertTrue(session.open(url: url))
        let baselineRevision = session.editRevision

        session.updateContent("Original")
        XCTAssertEqual(session.editRevision, baselineRevision)
        XCTAssertFalse(session.hasUnsavedChanges)

        session.updateContent("Edited")
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertEqual(session.editRevision, baselineRevision + 1)

        session.updateContent("Original")
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertEqual(session.editRevision, baselineRevision + 2)

        session.updateContent("Edited again")
        session.discardUnsavedChanges()
        XCTAssertEqual(session.content, "Original")
        XCTAssertFalse(session.hasUnsavedChanges)
        session.close()
    }

    func testOpenRefusesToDropUnsavedChangesUnlessRequested() throws {
        let firstURL = try makeMarkdownFile("first.md", content: "First")
        let secondURL = try makeMarkdownFile("second.md", content: "Second")
        let session = MarkdownResourceSession(access: SecurityScopeSpy())
        session.isAutoSaveEnabled = false

        XCTAssertTrue(session.open(url: firstURL))
        session.updateContent("Unsaved edit")

        XCTAssertFalse(session.open(url: secondURL, discardingUnsavedChanges: false))
        XCTAssertEqual(session.lastError, .unsavedChanges)
        XCTAssertEqual(session.fileURL, firstURL)
        XCTAssertEqual(session.content, "Unsaved edit")

        XCTAssertTrue(session.open(url: secondURL, discardingUnsavedChanges: true))
        XCTAssertEqual(session.fileURL, secondURL)
        XCTAssertEqual(session.content, "Second")
        XCTAssertFalse(session.hasUnsavedChanges)
        session.close()
    }

    func testSaveAsWritesCopyAdoptsNewSessionAndPreservesOriginal() throws {
        let originalURL = try makeMarkdownFile("original.md", content: "Original")
        let copyURL = directory.url.appendingPathComponent("copy.md")
        let spy = SecurityScopeSpy()
        let session = MarkdownResourceSession(access: spy)
        session.isAutoSaveEnabled = false

        XCTAssertTrue(session.open(url: originalURL))
        session.updateContent("Updated draft")

        XCTAssertEqual(session.saveAs(to: copyURL, overwrite: false), .saved)
        XCTAssertEqual(session.fileURL, copyURL)
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertEqual(try String(contentsOf: originalURL, encoding: .utf8), "Original")
        XCTAssertEqual(try String(contentsOf: copyURL, encoding: .utf8), "Updated draft")
        XCTAssertTrue(spy.stops.contains(originalURL))

        // Saving over an existing target without overwrite is refused.
        XCTAssertEqual(session.saveAs(to: originalURL, overwrite: false), .failed(.store(.targetExists(originalURL))))
        XCTAssertEqual(session.fileURL, copyURL)
        session.close()
    }

    func testAutoSaveCoalescesRapidEditsIntoSingleAtomicWrite() async throws {
        let url = try makeMarkdownFile(content: "Initial")
        let io = ScriptedDocumentStoreIO()
        let session = MarkdownResourceSession(access: SecurityScopeSpy(), io: io)
        session.autoSaveDebounceNanoseconds = 60_000_000
        XCTAssertTrue(session.open(url: url))

        session.updateContent("Draft 1")
        try await Task.sleep(nanoseconds: 15_000_000)
        session.updateContent("Draft 2")
        XCTAssertEqual(io.replacementCount, 0)

        let deadline = Date().addingTimeInterval(2.0)
        while session.autoSaveStatus == .pending || session.autoSaveStatus == .saving {
            if Date() > deadline {
                XCTFail("Timed out waiting for Markdown autosave")
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(session.autoSaveStatus, .saved)
        XCTAssertEqual(io.replacementCount, 1)
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Draft 2")
        session.close()
    }

    // MARK: - Existing-File Collisions

    func testCreateRefusesExistingFileAndPreservesOriginalBytes() throws {
        let existingURL = try makeMarkdownFile("existing.notes.md", content: "Important user notes")
        let spy = SecurityScopeSpy()
        let session = MarkdownResourceSession(access: spy)

        XCTAssertFalse(session.create(at: existingURL, initialContent: "Overwrite attempt"))
        XCTAssertEqual(session.lastError, .targetExists(existingURL))
        XCTAssertFalse(session.isLoaded)
        XCTAssertEqual(try String(contentsOf: existingURL, encoding: .utf8), "Important user notes")
        XCTAssertEqual(spy.starts, [existingURL])
        XCTAssertEqual(spy.stops, [existingURL])
    }

    func testCreateRefusesSymlinkAndRacedTargetCreation() throws {
        let targetURL = try makeMarkdownFile("real.md", content: "Real")
        let linkURL = directory.url.appendingPathComponent("alias.notes.md")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        let session = MarkdownResourceSession(access: SecurityScopeSpy())
        XCTAssertFalse(session.create(at: linkURL, initialContent: "New"))
        XCTAssertEqual(session.lastError, .targetExists(linkURL))
        XCTAssertEqual(try String(contentsOf: targetURL, encoding: .utf8), "Real")

        // Simulate another process creating the target right before coordinated move,
        // even with identical bytes!
        let racedURL = directory.url.appendingPathComponent("raced.notes.md")
        let io = ScriptedDocumentStoreIO()
        io.beforeCoordinatedWrite = {
            try? Data("Same".utf8).write(to: racedURL)
        }
        let racedSession = MarkdownResourceSession(access: SecurityScopeSpy(), io: io)
        XCTAssertFalse(racedSession.create(at: racedURL, initialContent: "Same"))
        XCTAssertEqual(try String(contentsOf: racedURL, encoding: .utf8), "Same")
    }

    // MARK: - External Modification Conflicts & Recovery

    func testExternalModificationRefusesSilentOverwriteAndPreservesUnsavedText() throws {
        let url = try makeMarkdownFile(content: "# Paper\nInitial note\n")
        let session = MarkdownResourceSession(access: SecurityScopeSpy())
        session.isAutoSaveEnabled = false
        XCTAssertTrue(session.open(url: url))

        session.updateContent("# Paper\nYoPDF unsaved edit\n")
        XCTAssertEqual(try session.checkExternalChange(), .unchanged)

        // Simulate Obsidian modifying the same file on disk.
        try Data("# Paper\nObsidian external edit\n".utf8).write(to: url)
        guard case .modified = try session.checkExternalChange() else {
            return XCTFail("Expected .modified external change")
        }

        let outcome = session.save()
        guard case .conflict(.externalModificationDetected(.modified)) = outcome else {
            return XCTFail("Expected conflict, got \(outcome)")
        }

        // Neither external disk bytes nor in-memory unsaved text may be lost.
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Paper\nObsidian external edit\n")
        XCTAssertEqual(session.content, "# Paper\nYoPDF unsaved edit\n")
        XCTAssertTrue(session.hasUnsavedChanges)

        // Reload without discarding is refused; explicit reload adopts disk version.
        XCTAssertFalse(session.reload(discardingUnsavedChanges: false))
        XCTAssertEqual(session.lastError, .unsavedChanges)
        XCTAssertEqual(session.content, "# Paper\nYoPDF unsaved edit\n")

        XCTAssertTrue(session.reload(discardingUnsavedChanges: true))
        XCTAssertEqual(session.content, "# Paper\nObsidian external edit\n")
        XCTAssertFalse(session.hasUnsavedChanges)
        session.close()
    }

    func testExternalReplacementAndDeletionAreDetected() throws {
        let url = try makeMarkdownFile(content: "Original")
        let session = MarkdownResourceSession(access: SecurityScopeSpy())
        session.isAutoSaveEnabled = false
        XCTAssertTrue(session.open(url: url))
        session.updateContent("Local unsaved")

        // Atomic replacement by another editor (new inode, even with identical content).
        let temp = directory.url.appendingPathComponent("replacement.tmp")
        try Data("Original".utf8).write(to: temp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)

        guard case .replaced = try session.checkExternalChange() else {
            return XCTFail("Expected .replaced when inode changed")
        }
        guard case .conflict(.externalModificationDetected(.replaced)) = session.save() else {
            return XCTFail("Expected conflict on replaced file")
        }
        XCTAssertEqual(session.content, "Local unsaved")

        // External deletion.
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(try session.checkExternalChange(), .missing)
        guard case .failed(.store(.fileMissing)) = session.save() else {
            return XCTFail("Expected fileMissing on deleted file")
        }
        XCTAssertEqual(session.content, "Local unsaved")
        XCTAssertTrue(session.hasUnsavedChanges)
        session.close()
    }

    func testAutoSaveConflictLeavesExternalBytesAndUnsavedTextIntact() async throws {
        let url = try makeMarkdownFile(content: "Base")
        let session = MarkdownResourceSession(access: SecurityScopeSpy())
        session.autoSaveDebounceNanoseconds = 30_000_000
        XCTAssertTrue(session.open(url: url))

        session.updateContent("Local edit")
        try Data("External edit".utf8).write(to: url)

        let deadline = Date().addingTimeInterval(2.0)
        while session.autoSaveStatus == .pending || session.autoSaveStatus == .saving {
            if Date() > deadline {
                XCTFail("Timed out waiting for autosave conflict")
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        guard case .failed(.conflict(.externalModificationDetected(.modified))) = session.autoSaveStatus else {
            return XCTFail("Expected autosave conflict failure, got \(session.autoSaveStatus)")
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "External edit")
        XCTAssertEqual(session.content, "Local edit")
        XCTAssertTrue(session.hasUnsavedChanges)
        session.close()
    }

    func testUncertainReplacementKeepsUnsavedStateAndRefreshResolves() throws {
        let url = try makeMarkdownFile(content: "Before")
        let io = ScriptedDocumentStoreIO()
        let session = MarkdownResourceSession(access: SecurityScopeSpy(), io: io)
        session.isAutoSaveEnabled = false
        XCTAssertTrue(session.open(url: url))

        let backup = directory.url.appendingPathComponent("backup-before.md")
        session.updateContent("After")
        io.partialCommit = .originalMovedTo(backup)

        let outcome = session.save()
        guard case let .uncertain(_, recoveryURLs) = outcome else {
            return XCTFail("Expected uncertain outcome, got \(outcome)")
        }
        XCTAssertFalse(recoveryURLs.isEmpty)
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertEqual(session.content, "After")
        XCTAssertEqual(session.documentSession?.state, .needsRefresh)

        // While target is still missing, refresh refuses to guess.
        guard case .failed(.store(.fileMissing)) = session.refreshPendingSave() else {
            return XCTFail("Expected fileMissing while target is absent")
        }
        XCTAssertEqual(session.documentSession?.state, .needsRefresh)

        // Simulate user/system restoring the original backup to `url`.
        io.partialCommit = nil
        try FileManager.default.moveItem(at: backup, to: url)
        guard case .failed(.store(.replacementFailed)) = session.refreshPendingSave() else {
            return XCTFail("Expected replacementFailed once original was verified intact")
        }
        XCTAssertEqual(session.documentSession?.state, .open)
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertEqual(session.content, "After")

        // Now retrying save succeeds cleanly.
        XCTAssertEqual(session.save(), .saved)
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "After")
        session.close()
    }

    // MARK: - Missing, Invalid, Permission Denied, Read-Only

    func testOpenRejectsUnsupportedMissingDirectoryAndInvalidUTF8() throws {
        let spy = SecurityScopeSpy()
        let session = MarkdownResourceSession(access: spy)

        // Non-file URL
        XCTAssertFalse(session.open(url: URL(string: "https://example.com/note.md")!))
        XCTAssertEqual(session.lastError, .notAFileURL)

        // Unsupported extension
        let pdfURL = try directory.write("paper.pdf", Data("%PDF-1.4".utf8))
        XCTAssertFalse(session.open(url: pdfURL))
        XCTAssertEqual(session.lastError, .unsupportedType("pdf"))

        // Missing file
        let missingURL = directory.url.appendingPathComponent("missing.md")
        XCTAssertFalse(session.open(url: missingURL))
        XCTAssertEqual(session.lastError, .fileMissing(missingURL))

        // Directory
        let folderURL = directory.url.appendingPathComponent("folder.md", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        XCTAssertFalse(session.open(url: folderURL))
        XCTAssertEqual(session.lastError, .unsupportedFileSituation(.notARegularFile, folderURL))

        // Invalid UTF-8
        let invalidUTF8URL = try directory.write("binary.md", Data([0xFF, 0xFE, 0x80, 0x81]))
        XCTAssertFalse(session.open(url: invalidUTF8URL))
        XCTAssertEqual(session.lastError, .invalidUTF8(invalidUTF8URL))

        XCTAssertEqual(spy.starts.count, spy.stops.count, "All failed opens must release candidate scopes")
    }

    func testReadOnlyFileRefusesSavePreservesUnsavedTextAndAllowsSaveAs() throws {
        let url = try makeMarkdownFile("readonly.md", content: "Locked content")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)

        let session = MarkdownResourceSession(access: SecurityScopeSpy())
        session.isAutoSaveEnabled = false
        XCTAssertTrue(session.open(url: url))
        XCTAssertTrue(session.isReadOnlyAtOpen)

        session.updateContent("Unsaved edits on read-only file")
        XCTAssertEqual(session.save(), .failed(.store(.readOnly(url))))
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertEqual(session.content, "Unsaved edits on read-only file")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Locked content")

        let writableCopy = directory.url.appendingPathComponent("writable-copy.md")
        XCTAssertEqual(session.saveAs(to: writableCopy), .saved)
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertEqual(try String(contentsOf: writableCopy, encoding: .utf8), "Unsaved edits on read-only file")
        session.close()
    }

    func testCreateInReadOnlyOrMissingDirectoryFailsCleanly() throws {
        let missingParent = directory.url.appendingPathComponent("nonexistent/note.md")
        let session = MarkdownResourceSession(access: SecurityScopeSpy())
        XCTAssertFalse(session.create(at: missingParent, initialContent: "Hi"))
        XCTAssertEqual(session.lastError, .fileMissing(missingParent.deletingLastPathComponent()))

        let readOnlyDir = directory.url.appendingPathComponent("ro-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnlyDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlyDir.path)

        let noteInRO = readOnlyDir.appendingPathComponent("note.md")
        XCTAssertFalse(session.create(at: noteInRO, initialContent: "Hi"))
        XCTAssertEqual(session.lastError, .permissionDenied(readOnlyDir))
    }

    // MARK: - Unicode & Markdown Source Preservation

    func testPreservesUnicodeFrontmatterLaTeXAndLineEndingsBitForBit() throws {
        let rawCRLF = [
            "---",
            "title: \"Attention Is All You Need\"",
            "tags: [transformer, 中文筆記, 日本語]",
            "---",
            "",
            "# 筆記 🧪",
            "",
            "Inline math $E = mc^2$ and block:",
            "",
            "$$",
            "\\text{Attention}(Q, K, V) = \\text{softmax}\\left(\\frac{QK^T}{\\sqrt{d_k}}\\right)V",
            "$$",
            "",
            "| Col A | Col B |",
            "| :--- | :--- |",
            "| cafe\u{0301} | café |",
            "",
            "Trailing two spaces  ",
            "Next line without trailing newline"
        ].joined(separator: "\r\n")

        let url = try makeMarkdownFile("complex.md", content: rawCRLF)
        let session = MarkdownResourceSession(access: SecurityScopeSpy())
        session.isAutoSaveEnabled = false
        XCTAssertTrue(session.open(url: url))

        XCTAssertEqual(session.detectedLineEnding, .crlf)
        XCTAssertEqual(session.content, rawCRLF)

        // Simulate editor inserting LF while preserving CRLF convention.
        session.updateContent(rawCRLF + "\nAppended line", preserveLineEndings: true)
        XCTAssertTrue(session.content.hasSuffix("\r\nAppended line"))
        XCTAssertEqual(session.save(), .saved)

        let diskData = try Data(contentsOf: url)
        XCTAssertEqual(diskData, Data((rawCRLF + "\r\nAppended line").utf8))
        session.close()
    }

    func testPreservesMixedLineEndingsAndUTF8BOM() throws {
        let rawMixed = "\u{FEFF}# Title\r\nLine 2\nLine 3\rLine 4"
        let url = try makeMarkdownFile("mixed.md", content: rawMixed)
        let session = MarkdownResourceSession(access: SecurityScopeSpy())
        session.isAutoSaveEnabled = false
        XCTAssertTrue(session.open(url: url))

        XCTAssertEqual(session.detectedLineEnding, .mixed)
        session.updateContent(rawMixed + "\nLine 5", preserveLineEndings: true)
        XCTAssertEqual(session.save(), .saved)

        let diskData = try Data(contentsOf: url)
        XCTAssertEqual(diskData, Data((rawMixed + "\nLine 5").utf8))
        session.close()
    }

    // MARK: - Multi-Pane Resource Sharing & Security Scope Lifecycle

    func testMultiplePanesShareOneMarkdownResourceSessionAndSingleWriter() throws {
        let url = try makeMarkdownFile("shared.md", content: "# Shared")
        let linkURL = directory.url.appendingPathComponent("shared-link.md")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: url)

        let spy = SecurityScopeSpy()
        let pool = MarkdownResourcePool(access: spy)
        let paneA = PaneID()
        let paneB = PaneID()

        let sessionA = try pool.open(url: url, for: paneA).get()
        let sessionB = try pool.open(url: linkURL, for: paneB).get()

        XCTAssertTrue(sessionA === sessionB, "Panes referencing same Markdown file must share one session")
        XCTAssertEqual(sessionA.activeLeaseCount, 2)
        XCTAssertEqual(spy.starts.count, 1, "Only one DocumentSession security scope should be acquired")
        XCTAssertEqual(pool.activeSessions.count, 1)

        var observedEvents: [MarkdownResourceEvent] = []
        sessionB.events
            .sink { observedEvents.append($0) }
            .store(in: &cancellables)

        sessionA.updateContent("# Shared\nEdited in Pane A", from: paneA)
        XCTAssertEqual(sessionB.content, "# Shared\nEdited in Pane A")
        XCTAssertTrue(observedEvents.contains(.contentChanged(sourcePaneID: paneA)))
        XCTAssertEqual(sessionB.save(), .saved)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Shared\nEdited in Pane A")

        // Closing Pane A retains session and security scope for Pane B.
        pool.release(session: sessionA, for: paneA)
        XCTAssertTrue(sessionB.isLoaded)
        XCTAssertEqual(sessionB.activeLeaseCount, 1)
        XCTAssertEqual(spy.stops, [])
        XCTAssertEqual(pool.activeSessions.count, 1)

        // Closing Pane B releases the final lease and closes DocumentSession.
        pool.release(session: sessionB, for: paneB)
        XCTAssertFalse(sessionB.isLoaded)
        XCTAssertEqual(sessionB.activeLeaseCount, 0)
        XCTAssertEqual(spy.stops, [url])
        XCTAssertEqual(pool.activeSessions.count, 0)
    }

    func testDeallocatingMarkdownResourceSessionReleasesSecurityScopeOnce() throws {
        let url = try makeMarkdownFile("dealloc.md", content: "Hello")
        let spy = SecurityScopeSpy()

        var session: MarkdownResourceSession? = MarkdownResourceSession(access: spy)
        XCTAssertTrue(session?.open(url: url) == true)
        XCTAssertEqual(spy.starts, [url])
        XCTAssertEqual(spy.stops, [])

        session = nil
        XCTAssertEqual(spy.stops, [url])
    }
}
