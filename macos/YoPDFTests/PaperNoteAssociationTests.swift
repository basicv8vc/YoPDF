import Foundation
import XCTest
@testable import YoPDFCore

@MainActor
final class PaperNoteAssociationTests: XCTestCase {

    private var directory: TemporaryDirectory!
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory("paper-note-assoc")
        suiteName = "YoPDFPaperNoteAssociationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        directory?.remove()
        directory = nil
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private var storageURL: URL {
        directory.url.appendingPathComponent("AppSupport/YoPDF/associations.json")
    }

    private func makePDF(named name: String, in folder: URL? = nil, label: String? = nil) throws -> (URL, Data) {
        let data = try PDFFixtureFactory.makePDFData(pageCount: 1) { _ in
            label ?? "Paper \(name)"
        }
        let targetDir = folder ?? directory.url
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let url = targetDir.appendingPathComponent(name)
        try data.write(to: url)
        return (url, data)
    }

    private func makeStore(
        access: any SecurityScopeAccessing = SecurityScopeSpy(),
        authorizer: (any NoteLocationAuthorizing)? = nil,
        bookmarkDataProvider: (@MainActor (URL) throws -> Data)? = nil,
        bookmarkResolver: (@MainActor (Data) throws -> ResolvedBookmark)? = nil
    ) -> PaperNoteAssociationStore {
        PaperNoteAssociationStore(
            storageURL: storageURL,
            defaults: defaults,
            access: access,
            locationAuthorizer: authorizer,
            bookmarkDataProvider: bookmarkDataProvider,
            bookmarkResolver: bookmarkResolver
        )
    }

    // MARK: - Default Naming & Creation Beside PDF

    func testDefaultNoteNamingConvention() {
        let normal = URL(fileURLWithPath: "/Papers/Attention Is All You Need.pdf")
        XCTAssertEqual(
            PaperNoteAssociationStore.defaultNoteFilename(forPDF: normal),
            "Attention Is All You Need.notes.md"
        )

        let multiDot = URL(fileURLWithPath: "/Papers/paper.v2.final.pdf")
        XCTAssertEqual(
            PaperNoteAssociationStore.defaultNoteFilename(forPDF: multiDot),
            "paper.v2.final.notes.md"
        )
    }

    func testCreateDefaultNoteBesidePDFDoesNotModifyPDFBytesOrMetadata() throws {
        let (pdfURL, pdfBytes) = try makePDF(named: "Vaswani2017.pdf")
        let originalPDFHash = TestPayload.sha256(pdfBytes)
        let spy = SecurityScopeSpy()
        let authorizer = ExplicitNoteLocationAuthorizer(authorizedDirectories: [directory.url])
        let store = makeStore(access: spy, authorizer: authorizer)

        let expectedNoteURL = directory.url.appendingPathComponent("Vaswani2017.notes.md")
        XCTAssertEqual(store.planDefaultNoteCreation(forPDF: pdfURL), .readyToCreate(targetURL: expectedNoteURL))

        let (association, session) = try store.createDefaultNote(
            forPDF: pdfURL,
            initialContent: "# Vaswani 2017\n"
        )
        defer { session.close() }

        XCTAssertEqual(association.pdfURL.standardizedFileURL, pdfURL.standardizedFileURL)
        XCTAssertEqual(association.markdownURL.standardizedFileURL, expectedNoteURL.standardizedFileURL)
        XCTAssertEqual(association.pdfContentHash, originalPDFHash)
        XCTAssertNotNil(association.pdfBookmarkData)
        XCTAssertNotNil(association.markdownBookmarkData)
        XCTAssertEqual(session.content, "# Vaswani 2017\n")

        // PDF bytes must be untouched (notes are never embedded into PDF metadata).
        XCTAssertEqual(TestPayload.sha256(try Data(contentsOf: pdfURL)), originalPDFHash)
        XCTAssertEqual(try String(contentsOf: expectedNoteURL, encoding: .utf8), "# Vaswani 2017\n")
    }

    // MARK: - Sibling Write Authorization & Read-Only Safety

    func testAccessToPDFDoesNotGrantPermissionToWriteSiblingFiles() throws {
        let papersDir = directory.url.appendingPathComponent("Papers", isDirectory: true)
        let (pdfURL, _) = try makePDF(named: "Protected.pdf", in: papersDir)
        let spy = SecurityScopeSpy()

        // Explicit authorizer grants NO directories (simulating sandboxed PDF-only file access).
        let strictAuthorizer = ExplicitNoteLocationAuthorizer(authorizedDirectories: [])
        let store = makeStore(access: spy, authorizer: strictAuthorizer)

        let expectedNoteURL = papersDir.appendingPathComponent("Protected.notes.md")
        XCTAssertEqual(
            store.planDefaultNoteCreation(forPDF: pdfURL),
            .locationAuthorizationRequired(suggestedURL: expectedNoteURL)
        )

        XCTAssertThrowsError(try store.createDefaultNote(forPDF: pdfURL, initialContent: "# Should fail")) { error in
            XCTAssertEqual(error as? PaperNoteAssociationError, .directoryNotAuthorized(papersDir.standardizedFileURL))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedNoteURL.path))
        XCTAssertTrue(store.associations.isEmpty)

        // SystemNoteLocationAuthorizer in sandboxed mode also refuses sibling writes.
        let sandboxAuthorizer = SystemNoteLocationAuthorizer(isSandboxed: true) { [] }
        let sandboxStore = makeStore(access: spy, authorizer: sandboxAuthorizer)
        XCTAssertEqual(
            sandboxStore.planDefaultNoteCreation(forPDF: pdfURL),
            .locationAuthorizationRequired(suggestedURL: expectedNoteURL)
        )

        // An explicit user-selected save destination (e.g. from NSSavePanel) succeeds.
        let (association, session) = try store.createNote(
            forPDF: pdfURL,
            at: expectedNoteURL,
            initialContent: "# User approved destination",
            isUserSelectedDestination: true
        )
        session.close()
        XCTAssertEqual(association.markdownURL.standardizedFileURL, expectedNoteURL.standardizedFileURL)
        XCTAssertEqual(try String(contentsOf: expectedNoteURL, encoding: .utf8), "# User approved destination")
    }

    func testReadOnlySiblingDirectoryRefusesDefaultCreationEvenWhenAuthorized() throws {
        let roDir = directory.url.appendingPathComponent("ReadOnlyPapers", isDirectory: true)
        let (pdfURL, _) = try makePDF(named: "ReadOnlyPaper.pdf", in: roDir)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: roDir.path)

        let authorizer = ExplicitNoteLocationAuthorizer(authorizedDirectories: [roDir])
        let store = makeStore(authorizer: authorizer)

        XCTAssertEqual(
            store.planDefaultNoteCreation(forPDF: pdfURL),
            .directoryNotWritable(roDir.standardizedFileURL)
        )
        XCTAssertThrowsError(try store.createDefaultNote(forPDF: pdfURL)) { error in
            XCTAssertEqual(error as? PaperNoteAssociationError, .directoryNotWritable(roDir.standardizedFileURL))
        }
    }

    // MARK: - Collision Handling & Linking Flows

    func testExistingNotesFileCollisionPromptsAndNeverOverwrites() throws {
        let (pdfURL, _) = try makePDF(named: "Paper.pdf")
        let existingNoteURL = directory.url.appendingPathComponent("Paper.notes.md")
        try Data("# My Existing Obsidian Note\n".utf8).write(to: existingNoteURL)

        let authorizer = ExplicitNoteLocationAuthorizer(authorizedDirectories: [directory.url])
        let store = makeStore(authorizer: authorizer)
        let alternativeURL = directory.url.appendingPathComponent("Paper.notes 2.md")

        XCTAssertEqual(
            store.planDefaultNoteCreation(forPDF: pdfURL),
            .existingNoteCollision(existingURL: existingNoteURL, suggestedAlternativeURL: alternativeURL)
        )

        XCTAssertThrowsError(try store.createDefaultNote(forPDF: pdfURL, initialContent: "OVERWRITE")) { error in
            XCTAssertEqual(error as? PaperNoteAssociationError, .noteFileAlreadyExists(existingNoteURL))
        }
        XCTAssertEqual(try String(contentsOf: existingNoteURL, encoding: .utf8), "# My Existing Obsidian Note\n")

        // Option 1: Link Existing Note without modifying it.
        let linked = try store.linkExistingNote(forPDF: pdfURL, markdownURL: existingNoteURL)
        XCTAssertEqual(linked.markdownURL.standardizedFileURL, existingNoteURL.standardizedFileURL)
        XCTAssertEqual(try String(contentsOf: existingNoteURL, encoding: .utf8), "# My Existing Obsidian Note\n")

        // Option 2: Create with another filename when starting fresh.
        let (altAssoc, altSession) = try store.createNote(
            forPDF: pdfURL,
            at: alternativeURL,
            initialContent: "# Second Note\n"
        )
        altSession.close()
        XCTAssertEqual(altAssoc.markdownURL.standardizedFileURL, alternativeURL.standardizedFileURL)
        XCTAssertEqual(try String(contentsOf: existingNoteURL, encoding: .utf8), "# My Existing Obsidian Note\n")
        XCTAssertEqual(try String(contentsOf: alternativeURL, encoding: .utf8), "# Second Note\n")
    }

    func testChooseExistingMarkdownFileAndRejectInvalidTargets() throws {
        let (pdfURL, _) = try makePDF(named: "Paper.pdf")
        let vaultDir = directory.url.appendingPathComponent("ObsidianVault/ReadingNotes", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
        let customNoteURL = vaultDir.appendingPathComponent("custom-reading-log.md")
        try Data("# Custom Log\n".utf8).write(to: customNoteURL)

        let store = makeStore()
        let assoc = try store.linkExistingNote(forPDF: pdfURL, markdownURL: customNoteURL)
        XCTAssertEqual(assoc.markdownURL.standardizedFileURL, customNoteURL.standardizedFileURL)
        XCTAssertEqual(store.associations.count, 1)

        // Reject non-Markdown file.
        let textFile = directory.url.appendingPathComponent("notes.txt")
        try Data("plain text".utf8).write(to: textFile)
        XCTAssertThrowsError(try store.linkExistingNote(forPDF: pdfURL, markdownURL: textFile)) { error in
            XCTAssertEqual(error as? PaperNoteAssociationError, .unsupportedMarkdownType("txt"))
        }

        // Reject invalid UTF-8 .md file.
        let badMD = directory.url.appendingPathComponent("corrupt.md")
        try Data([0xFF, 0xFE, 0x80]).write(to: badMD)
        XCTAssertThrowsError(try store.linkExistingNote(forPDF: pdfURL, markdownURL: badMD)) { error in
            XCTAssertEqual(error as? PaperNoteAssociationError, .invalidMarkdownUTF8(badMD.standardizedFileURL))
        }
    }

    // MARK: - Research Notebook Directory (Obsidian Vault)

    func testResearchNotebookDirectoryPlacesNotesInVaultEvenWhenSiblingDirUnauthorized() throws {
        let papersDir = directory.url.appendingPathComponent("ReadOnlyInbox", isDirectory: true)
        let (pdfURL, _) = try makePDF(named: "Transformer.pdf", in: papersDir)
        let vaultDir = directory.url.appendingPathComponent("ObsidianVault", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)

        // Sibling directory is NOT authorized!
        let strictAuthorizer = ExplicitNoteLocationAuthorizer(authorizedDirectories: [])
        let store = makeStore(authorizer: strictAuthorizer)

        try store.setNotebookDirectory(vaultDir)
        XCTAssertEqual(store.resolveNotebookDirectory(), .resolved(vaultDir.standardizedFileURL, refreshedBookmark: false))

        let expectedVaultNote = vaultDir.appendingPathComponent("Transformer.notes.md")
        XCTAssertEqual(store.planDefaultNoteCreation(forPDF: pdfURL), .readyToCreate(targetURL: expectedVaultNote))

        let (assoc, session) = try store.createDefaultNote(forPDF: pdfURL, initialContent: "# Transformer\n")
        session.close()
        XCTAssertEqual(assoc.markdownURL.standardizedFileURL, expectedVaultNote.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedVaultNote.path))

        // Persistence across relaunch.
        let relaunched = makeStore(authorizer: strictAuthorizer)
        XCTAssertEqual(relaunched.resolveNotebookDirectory(), .resolved(vaultDir.standardizedFileURL, refreshedBookmark: false))
        XCTAssertEqual(relaunched.associations.count, 1)

        // Clearing falls back to beside-PDF check (which asks for authorization).
        relaunched.clearNotebookDirectory()
        XCTAssertEqual(relaunched.resolveNotebookDirectory(), .notConfigured)
        let (otherPDF, _) = try makePDF(named: "Other.pdf", in: papersDir)
        XCTAssertEqual(
            relaunched.planDefaultNoteCreation(forPDF: otherPDF),
            .locationAuthorizationRequired(suggestedURL: papersDir.appendingPathComponent("Other.notes.md"))
        )
    }

    func testNotebookDirectoryCollisionAndStaleBookmarkRefresh() throws {
        let vaultDir = directory.url.appendingPathComponent("ObsidianVault", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
        let (pdfURL, _) = try makePDF(named: "Paper.pdf")
        let collidingVaultNote = vaultDir.appendingPathComponent("Paper.notes.md")
        try Data("Existing vault note".utf8).write(to: collidingVaultNote)

        let spy = SecurityScopeSpy()
        var refreshCount = 0
        let store = makeStore(
            access: spy,
            bookmarkDataProvider: { url in
                refreshCount += 1
                return Data("fresh-\(refreshCount)-\(url.path)".utf8)
            },
            bookmarkResolver: { data in
                let raw = String(decoding: data, as: UTF8.self)
                if raw.hasPrefix("fresh-1-") {
                    return ResolvedBookmark(url: vaultDir, isStale: true)
                }
                return ResolvedBookmark(url: vaultDir, isStale: false)
            }
        )

        try store.setNotebookDirectory(vaultDir)
        let resolution = store.resolveNotebookDirectory()
        XCTAssertEqual(resolution, .resolved(vaultDir.standardizedFileURL, refreshedBookmark: true))
        XCTAssertGreaterThanOrEqual(refreshCount, 2)

        guard case let .existingNoteCollision(existingURL, _) = store.planDefaultNoteCreation(forPDF: pdfURL) else {
            return XCTFail("Expected collision inside notebook directory")
        }
        XCTAssertEqual(existingURL.standardizedFileURL, collidingVaultNote.standardizedFileURL)
        XCTAssertEqual(try String(contentsOf: collidingVaultNote, encoding: .utf8), "Existing vault note")
    }

    // MARK: - Persistence Across Launches, Corrupted Storage, Unlink

    func testAssociationsPersistAcrossAppLaunchesAndUnlinkDoesNotDeleteFiles() throws {
        let (pdfURL, _) = try makePDF(named: "Persisted.pdf")
        let noteURL = try directory.write("Persisted.notes.md", Data("# Saved Note".utf8))

        let store = makeStore()
        let created = try store.linkExistingNote(forPDF: pdfURL, markdownURL: noteURL)

        let relaunched = makeStore()
        XCTAssertEqual(relaunched.associations.count, 1)
        let restored = try XCTUnwrap(relaunched.association(forPDF: pdfURL))
        XCTAssertEqual(restored.id, created.id)
        XCTAssertEqual(restored.pdfResourceID, created.pdfResourceID)
        XCTAssertEqual(restored.markdownResourceID, created.markdownResourceID)
        XCTAssertEqual(restored.pdfContentHash, created.pdfContentHash)
        XCTAssertEqual(restored.markdownURL.standardizedFileURL, noteURL.standardizedFileURL)

        // Unlinking removes metadata only; files stay on disk.
        relaunched.unlinkAssociation(id: restored.id)
        XCTAssertTrue(relaunched.associations.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdfURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: noteURL.path))

        let afterUnlink = makeStore()
        XCTAssertTrue(afterUnlink.associations.isEmpty)
    }

    func testCorruptedAssociationsFileIsPreservedAndBlocksOverwrite() throws {
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let garbage = Data("{ not valid associations json".utf8)
        try garbage.write(to: storageURL)

        let (pdfURL, _) = try makePDF(named: "Paper.pdf")
        let noteURL = try directory.write("Paper.notes.md", Data("# Note".utf8))

        let store = makeStore()
        XCTAssertTrue(store.hasUnreadableAssociationsStorage)
        XCTAssertThrowsError(try store.linkExistingNote(forPDF: pdfURL, markdownURL: noteURL)) { error in
            XCTAssertEqual(error as? PaperNoteAssociationError, .storageCorrupted)
        }
        XCTAssertEqual(try Data(contentsOf: storageURL), garbage)
    }

    // MARK: - Bookmark Refresh, Candidate Recovery, Explicit Relinking

    func testStaleBookmarksRefreshInsideActiveSecurityScope() throws {
        let (pdfURL, _) = try makePDF(named: "Paper.pdf")
        let noteURL = try directory.write("Paper.notes.md", Data("# Notes".utf8))
        let spy = SecurityScopeSpy()

        var issuedCount = 0
        var staleTriggered = false
        let store = makeStore(
            access: spy,
            bookmarkDataProvider: { url in
                issuedCount += 1
                return Data("bm|\(issuedCount)|\(url.path)".utf8)
            },
            bookmarkResolver: { data in
                let parts = String(decoding: data, as: UTF8.self).split(separator: "|", maxSplits: 2).map(String.init)
                let url = URL(fileURLWithPath: parts[2])
                let shouldBeStale = !staleTriggered && parts[1] == "2"
                if shouldBeStale { staleTriggered = true }
                return ResolvedBookmark(url: url, isStale: shouldBeStale)
            }
        )

        let initial = try store.linkExistingNote(forPDF: pdfURL, markdownURL: noteURL)
        let initialMDBookmark = initial.markdownBookmarkData
        let result = store.resolveAssociation(initial)

        XCTAssertTrue(result.didRefreshBookmarks)
        XCTAssertEqual(result.pdfResolution, .resolved(pdfURL.standardizedFileURL, refreshedBookmark: false))
        XCTAssertEqual(result.markdownResolution, .resolved(noteURL.standardizedFileURL, refreshedBookmark: true))
        XCTAssertNotEqual(result.association.markdownBookmarkData, initialMDBookmark)

        // Verify start -> stop balanced around every inspected resource.
        XCTAssertEqual(spy.starts.filter { $0 == noteURL.standardizedFileURL }.count,
                       spy.stops.filter { $0 == noteURL.standardizedFileURL }.count)
    }

    func testMovedFilesViaRealBookmarksAndExplicitRelinking() throws {
        let (pdfURL, _) = try makePDF(named: "MovedPaper.pdf")
        let noteURL = try directory.write("MovedPaper.notes.md", Data("# Moved Note".utf8))

        let store = makeStore()
        let assoc = try store.linkExistingNote(forPDF: pdfURL, markdownURL: noteURL)

        let movedNoteURL = directory.url.appendingPathComponent("Renamed.notes.md")
        try FileManager.default.moveItem(at: noteURL, to: movedNoteURL)

        let relaunched = makeStore()
        let resolvedAfterMove = relaunched.resolveAssociation(assoc)
        guard case let .resolved(resolvedMovedURL, didRefreshAfterMove) = resolvedAfterMove.markdownResolution else {
            return XCTFail("Expected .resolved after move, got \(resolvedAfterMove.markdownResolution)")
        }
        XCTAssertEqual(resolvedMovedURL, movedNoteURL.standardizedFileURL)
        if didRefreshAfterMove {
            XCTAssertNotEqual(resolvedAfterMove.association.markdownBookmarkData, assoc.markdownBookmarkData)
        }
        XCTAssertEqual(relaunched.associations.first?.markdownURL.standardizedFileURL, movedNoteURL.standardizedFileURL)

        // Now delete the note file -> must report missing and never guess by hash.
        try FileManager.default.removeItem(at: movedNoteURL)
        let duplicateElsewhere = try directory.write("CopyElsewhere.notes.md", Data("# Moved Note".utf8))

        let missingResult = relaunched.resolveAssociation(resolvedAfterMove.association)
        XCTAssertEqual(missingResult.markdownResolution, .missing(lastKnownURL: movedNoteURL.standardizedFileURL))

        // Explicit relink restores access and keeps the association ID.
        let relinked = try relaunched.relinkMarkdown(for: assoc.id, to: duplicateElsewhere)
        XCTAssertEqual(relinked.id, assoc.id)
        XCTAssertEqual(relinked.markdownURL.standardizedFileURL, duplicateElsewhere.standardizedFileURL)

        let afterRelink = makeStore()
        let resolvedAfterRelink = afterRelink.resolveAssociation(relinked)
        XCTAssertEqual(
            resolvedAfterRelink.markdownResolution,
            .resolved(duplicateElsewhere.standardizedFileURL, refreshedBookmark: false)
        )
    }

    func testBrokenPDFBookmarkUsesContentHashAsDiagnosticCandidateWithoutGuessingAmbiguousCopies() throws {
        let searchDir = directory.url.appendingPathComponent("SearchFolder", isDirectory: true)
        let (pdfURL, pdfData) = try makePDF(named: "Original.pdf")
        let noteURL = try directory.write("Original.notes.md", Data("# Note".utf8))

        // Simulate broken PDF bookmark once original is removed.
        let store = makeStore(
            bookmarkDataProvider: { url in
                Data("bm:\(url.path)".utf8)
            },
            bookmarkResolver: { data in
                let path = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "bm:", with: "")
                if !FileManager.default.fileExists(atPath: path) {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
                }
                return ResolvedBookmark(url: URL(fileURLWithPath: path), isStale: false)
            }
        )

        let assoc = try store.linkExistingNote(forPDF: pdfURL, markdownURL: noteURL)
        try FileManager.default.removeItem(at: pdfURL)

        // 0 candidates -> .missing
        let missing = store.resolveAssociation(assoc, candidatePDFSearchDirectories: [searchDir])
        XCTAssertEqual(missing.pdfResolution, .missing(lastKnownURL: pdfURL.standardizedFileURL))

        // 1 matching candidate -> .singleCandidate
        try FileManager.default.createDirectory(at: searchDir, withIntermediateDirectories: true)
        let candidate1 = searchDir.appendingPathComponent("Copy1.pdf")
        try pdfData.write(to: candidate1)
        let single = store.resolveAssociation(assoc, candidatePDFSearchDirectories: [searchDir])
        XCTAssertEqual(
            single.pdfResolution,
            .singleCandidate(candidate1.resolvingSymlinksInPath().standardizedFileURL)
        )

        // 2 matching candidates -> .ambiguousCandidates (must never guess)
        let candidate2 = searchDir.appendingPathComponent("Copy2.pdf")
        try pdfData.write(to: candidate2)
        let ambiguous = store.resolveAssociation(assoc, candidatePDFSearchDirectories: [searchDir])
        guard case let .ambiguousCandidates(urls) = ambiguous.pdfResolution else {
            return XCTFail("Expected ambiguousCandidates, got \(ambiguous.pdfResolution)")
        }
        XCTAssertEqual(urls.count, 2)

        // Explicit relink resolves the ambiguity and persists.
        let relinked = try store.relinkPDF(for: assoc.id, to: candidate2)
        XCTAssertEqual(relinked.pdfURL.standardizedFileURL, candidate2.standardizedFileURL)
        XCTAssertEqual(
            store.resolveAssociation(relinked).pdfResolution,
            .resolved(candidate2.standardizedFileURL, refreshedBookmark: false)
        )
    }
}
