//
//  HeterogeneousMarkdownWorkspaceTests.swift
//  YoPDFTests
//
//  Created for Task P0-C-C: Heterogeneous Markdown Pane Integration.
//  Apache-2.0 Open Source License.
//

import AppKit
import XCTest
@testable import YoPDFCore

@MainActor
final class HeterogeneousMarkdownWorkspaceTests: XCTestCase {

    private var directory: TemporaryDirectory!
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory("heterogeneous-md-workspace")
        suiteName = "YoPDFHeterogeneousMarkdownTests.\(UUID().uuidString)"
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

    private func makeAssociationStore() -> PaperNoteAssociationStore {
        let storageURL = directory.url.appendingPathComponent("AppSupport/YoPDF/associations.json")
        return PaperNoteAssociationStore(
            storageURL: storageURL,
            defaults: defaults,
            access: SecurityScopeSpy(),
            bookmarkDataProvider: { url in Data(url.path.utf8) },
            bookmarkResolver: { data in
                let path = String(decoding: data, as: UTF8.self)
                return ResolvedBookmark(url: URL(fileURLWithPath: path), isStale: false)
            }
        )
    }

    private func makeWorkspace() -> WorkspaceWindowModel {
        WorkspaceWindowModel(
            markdownPool: MarkdownResourcePool(access: SecurityScopeSpy()),
            noteAssociationStore: makeAssociationStore(),
            modelFactory: { PDFDocumentModel() }
        )
    }

    private func writeTempPDF(named name: String, pageCount: Int = 5) throws -> URL {
        let data = try PDFFixtureFactory.makePDFData(pageCount: pageCount) { pageIndex in
            "Sample PDF \(name) page \(pageIndex + 1)"
        }
        let url = directory.url.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func writeTempMarkdown(named name: String, contents: String = "# Notes\n\nInitial text.\n") throws -> URL {
        let url = directory.url.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: - 1. Side-by-Side PDF + Paper Note

    func testOpeningPDFAndPaperNoteSideBySideSharesPoolAndKeepsPDFLive() throws {
        let pdfURL = try writeTempPDF(named: "attention.pdf")
        let workspace = makeWorkspace()
        defer { workspace.closeAllSessions() }

        guard case .opened = workspace.open(pdfURL) else {
            return XCTFail("Expected PDF to open")
        }

        let tab = workspace.activeTab
        let pdfPaneID = tab.activePaneID
        XCTAssertEqual(tab.activePaneKind, .pdf)

        let created = try workspace.noteAssociationStore.createDefaultNote(
            forPDF: pdfURL,
            initialContent: "# Attention\n\n"
        )
        let splitResult = workspace.openOrActivateMarkdownSession(
            created.session,
            associatedPDFURL: pdfURL,
            preferredSplitFrom: pdfPaneID,
            direction: .right
        )

        guard case let .success(mdPaneID) = splitResult else {
            return XCTFail("Expected Markdown split to succeed: \(splitResult)")
        }

        XCTAssertEqual(tab.layoutTree.paneCount, 2)
        XCTAssertEqual(tab.paneKind(for: pdfPaneID), .pdf)
        XCTAssertEqual(tab.paneKind(for: mdPaneID), .markdown)
        XCTAssertEqual(tab.activePaneID, mdPaneID)
        XCTAssertEqual(tab.activePaneKind, .markdown)
        XCTAssertTrue(tab.primaryPDFPaneSession?.id == pdfPaneID)
        XCTAssertEqual(tab.title, "attention.pdf")
        XCTAssertEqual(created.session.activeLeaseCount, 1)

        // Calling openOrActivate again with the same session activates the existing pane instead of creating a third.
        let secondResult = workspace.openOrActivateMarkdownSession(
            created.session,
            associatedPDFURL: pdfURL,
            preferredSplitFrom: pdfPaneID,
            direction: .right
        )
        guard case let .success(reusedPaneID) = secondResult else {
            return XCTFail("Expected reuse of existing Markdown pane")
        }
        XCTAssertEqual(reusedPaneID, mdPaneID)
        XCTAssertEqual(tab.layoutTree.paneCount, 2)
    }

    // MARK: - 2. Splitting Markdown Pane & Shared Resource Lease

    func testSplittingMarkdownPaneSharesResourceSessionWithIndependentModels() throws {
        let mdURL = try writeTempMarkdown(named: "paper.notes.md")
        let workspace = makeWorkspace()
        defer { workspace.closeAllSessions() }

        guard case let .opened(_, paneA) = workspace.openMarkdown(mdURL) else {
            return XCTFail("Expected Markdown file to open in active empty tab")
        }

        let tab = workspace.activeTab
        XCTAssertTrue(tab.hasLoadedContent)
        XCTAssertEqual(tab.activePaneKind, .markdown)
        XCTAssertFalse(tab.model.isLoaded, "Markdown-only tab keeps unloaded fallback PDFDocumentModel without crashing")
        XCTAssertEqual(tab.title, "paper.notes.md")

        let paneB = try workspace.splitActivePane(direction: .right)
        XCTAssertEqual(tab.layoutTree.paneCount, 2)

        guard let sessionA = tab.markdownPaneSessions[paneA],
              let sessionB = tab.markdownPaneSessions[paneB] else {
            return XCTFail("Expected two MarkdownPaneSessions")
        }

        XCTAssertTrue(sessionA.resourceSession === sessionB.resourceSession)
        XCTAssertTrue(sessionA.paneModel !== sessionB.paneModel)
        XCTAssertTrue(sessionA.paneModel.editorController !== sessionB.paneModel.editorController)
        XCTAssertEqual(sessionA.resourceSession.activeLeaseCount, 2)

        sessionA.resourceSession.updateContent("# Updated\n", from: paneA)
        XCTAssertEqual(sessionB.resourceSession.content, "# Updated\n")
        XCTAssertTrue(sessionB.resourceSession.hasUnsavedChanges)

        // Closing one pane while the other still holds a lease must NOT prompt or discard unsaved edits.
        XCTAssertEqual(workspace.closePanePrompt(tabID: tab.id, paneID: paneB), ReaderPrompt.none)
        let closedB = try workspace.closePane(tabID: tab.id, paneID: paneB)
        XCTAssertTrue(closedB)
        XCTAssertEqual(sessionA.resourceSession.activeLeaseCount, 1)
        XCTAssertTrue(sessionA.resourceSession.hasUnsavedChanges)
    }

    // MARK: - 3. Dirty Final Markdown Pane Close & Tab Close Prompts

    func testClosingDirtyFinalMarkdownPanePromptsAndRespectsSaveOrDiscard() throws {
        let pdfURL = try writeTempPDF(named: "paper.pdf")
        let mdURL = try writeTempMarkdown(named: "paper.notes.md", contents: "Baseline\n")
        let workspace = makeWorkspace()
        defer { workspace.closeAllSessions() }

        guard case .opened = workspace.open(pdfURL) else {
            return XCTFail("Failed to open PDF")
        }
        let tab = workspace.activeTab
        let pdfPaneID = tab.activePaneID

        guard case let .success(mdPaneID) = workspace.openMarkdownInSplit(
            url: mdURL,
            associatedPDFURL: pdfURL,
            in: tab.id,
            adjacentTo: pdfPaneID,
            direction: .right
        ), let mdSession = tab.markdownPaneSessions[mdPaneID] else {
            return XCTFail("Failed to open Markdown split")
        }

        mdSession.resourceSession.isAutoSaveEnabled = false
        mdSession.resourceSession.updateContent("Baseline\nEdited line\n", from: mdPaneID)

        // Unsaved changes are tracked at the workspace level for WindowCloseGuard / QuitCoordinator.
        XCTAssertTrue(workspace.unsavedWork.documentHasChanges)
        XCTAssertEqual(workspace.closePanePrompt(tabID: tab.id, paneID: mdPaneID), .document)

        // Direct close refuses to silently discard dirty Markdown edits.
        XCTAssertFalse(try workspace.closePane(tabID: tab.id, paneID: mdPaneID))
        XCTAssertEqual(tab.layoutTree.paneCount, 2)

        // Discarding lets close succeed cleanly and restores disk baseline.
        workspace.discardPaneChanges(tabID: tab.id, paneID: mdPaneID)
        XCTAssertFalse(mdSession.resourceSession.hasUnsavedChanges)
        XCTAssertTrue(try workspace.closePane(tabID: tab.id, paneID: mdPaneID))
        XCTAssertEqual(tab.layoutTree.paneCount, 1)
        XCTAssertEqual(mdSession.resourceSession.activeLeaseCount, 0)
    }

    func testDirtyMarkdownPreventsSilentTabCloseUntilSavedOrDiscarded() throws {
        let mdURL1 = try writeTempMarkdown(named: "one.md", contents: "One\n")
        let mdURL2 = try writeTempMarkdown(named: "two.md", contents: "Two\n")
        let workspace = makeWorkspace()
        defer { workspace.closeAllSessions() }

        guard case .opened = workspace.openMarkdown(mdURL1) else {
            return XCTFail("Failed to open first Markdown file")
        }
        guard case let .opened(tab2ID, pane2ID) = workspace.openMarkdown(mdURL2) else {
            return XCTFail("Failed to open second Markdown file")
        }

        let tab2 = try XCTUnwrap(workspace.session(tabID: tab2ID))
        let mdSession2 = try XCTUnwrap(tab2.markdownPaneSessions[pane2ID])
        mdSession2.resourceSession.isAutoSaveEnabled = false
        mdSession2.resourceSession.updateContent("Two edited\n", from: pane2ID)

        XCTAssertEqual(workspace.closeTabPrompt(tabID: tab2ID), .document)
        XCTAssertFalse(workspace.closeTab(tabID: tab2ID))

        let saveOutcome = mdSession2.resourceSession.save()
        XCTAssertEqual(saveOutcome, .saved)
        XCTAssertEqual(workspace.closeTabPrompt(tabID: tab2ID), ReaderPrompt.none)
        XCTAssertTrue(workspace.closeTab(tabID: tab2ID))
        XCTAssertEqual(mdSession2.resourceSession.activeLeaseCount, 0)
    }

    // MARK: - 4. Drag / Move Markdown Pane Across Tabs

    func testMovingMarkdownPaneAcrossTabsPreservesSessionAndUnsavedEdits() throws {
        let pdfURL1 = try writeTempPDF(named: "one.pdf")
        let pdfURL2 = try writeTempPDF(named: "two.pdf")
        let mdURL = try writeTempMarkdown(named: "shared.notes.md", contents: "Start\n")
        let workspace = makeWorkspace()
        defer { workspace.closeAllSessions() }

        guard case let .opened(tab1ID) = workspace.open(pdfURL1),
              case let .opened(tab2ID) = workspace.open(pdfURL2) else {
            return XCTFail("Failed to open PDFs")
        }

        let tab1 = try XCTUnwrap(workspace.session(tabID: tab1ID))
        let tab2 = try XCTUnwrap(workspace.session(tabID: tab2ID))
        let pdfPane1 = tab1.activePaneID
        let pdfPane2 = tab2.activePaneID

        guard case let .success(mdPaneID) = workspace.openMarkdownInSplit(
            url: mdURL,
            associatedPDFURL: pdfURL1,
            in: tab1ID,
            adjacentTo: pdfPane1,
            direction: .right
        ), let originalMDSession = tab1.markdownPaneSessions[mdPaneID] else {
            return XCTFail("Failed to open Markdown in tab1")
        }

        originalMDSession.resourceSession.isAutoSaveEnabled = false
        originalMDSession.resourceSession.updateContent("Unsaved draft line\n", from: mdPaneID)

        let movedPaneID = try workspace.movePane(
            sourceTabID: tab1ID,
            paneID: mdPaneID,
            toDestinationTabID: tab2ID,
            adjacentTo: pdfPane2,
            direction: .right
        )

        XCTAssertEqual(movedPaneID, mdPaneID)
        XCTAssertEqual(tab1.layoutTree.paneCount, 1)
        XCTAssertNil(tab1.markdownPaneSessions[mdPaneID])
        XCTAssertEqual(tab2.layoutTree.paneCount, 2)

        let transferred = try XCTUnwrap(tab2.markdownPaneSessions[mdPaneID])
        XCTAssertTrue(transferred.resourceSession === originalMDSession.resourceSession)
        XCTAssertEqual(transferred.resourceSession.content, "Unsaved draft line\n")
        XCTAssertEqual(transferred.resourceSession.activeLeaseCount, 1)
    }

    // MARK: - 5. Drop Layout Validation Before Opening Markdown

    func testOpenMarkdownInSplitRefusesWhenMaxPanesReachedWithoutLeasingSession() throws {
        let pdfURL = try writeTempPDF(named: "max.pdf")
        let mdURL = try writeTempMarkdown(named: "extra.md")
        let workspace = makeWorkspace()
        defer { workspace.closeAllSessions() }

        guard case .opened = workspace.open(pdfURL) else {
            return XCTFail("Failed to open PDF")
        }

        let tab = workspace.activeTab
        for _ in 1..<LayoutPolicy.default.maxPanes {
            _ = try workspace.splitActivePane(direction: .right)
        }
        XCTAssertEqual(tab.layoutTree.paneCount, LayoutPolicy.default.maxPanes)

        let result = workspace.openMarkdownInSplit(
            url: mdURL,
            in: tab.id,
            adjacentTo: tab.activePaneID,
            direction: .right
        )
        switch result {
        case .success:
            XCTFail("Expected split to fail at maxPanes")
        case let .failure(error):
            XCTAssertEqual(
                error as? LayoutMutationError,
                .maximumPaneLimitReached(limit: LayoutPolicy.default.maxPanes)
            )
        }
        XCTAssertNil(workspace.findMarkdownResourceSession(for: mdURL))
    }

    // MARK: - 6. Portable Citations & Link Resolution

    func testPortableCitationFormattingAndLinkDetection() {
        let notesURL = URL(fileURLWithPath: "/tmp/research/notes/paper.notes.md")
        let pdfURL = URL(fileURLWithPath: "/tmp/research/papers/Attention Is All You Need.pdf")

        let pageOnly = MarkdownCitation.formatCitation(
            pdfURL: pdfURL,
            title: "Attention [2017]",
            pageIndex: 4,
            selectedText: nil,
            relativeTo: notesURL
        )
        XCTAssertEqual(
            pageOnly,
            "[Attention (2017), p. 5](../papers/Attention%20Is%20All%20You%20Need.pdf#page=5)"
        )

        let withExcerpt = MarkdownCitation.formatCitation(
            pdfURL: pdfURL,
            title: "Attention",
            pageIndex: 2,
            selectedText: "First line\nSecond line",
            relativeTo: URL(fileURLWithPath: "/tmp/research/papers/paper.notes.md")
        )
        XCTAssertEqual(
            withExcerpt,
            "> First line\n> Second line\n\n— [Attention, p. 3](./Attention%20Is%20All%20You%20Need.pdf#page=3)\n"
        )

        let doc = "See [Section 3](./Attention%20Is%20All%20You%20Need.pdf#page=5) and ![img](./fig.png)."
        let linkStart = (doc as NSString).range(of: "[Section 3]").location
        // Match full link inside doc
        let targetRange = (doc as NSString).range(of: "Section 3")
        let detected = MarkdownCitation.linkAt(utf16Offset: targetRange.location + 2, in: doc)
        XCTAssertEqual(detected?.target.pageNumber, 5)
        XCTAssertEqual(detected?.target.path, "./Attention Is All You Need.pdf")

        let resolved = MarkdownCitation.resolveTargetURL(
            for: detected!.target.path,
            relativeTo: URL(fileURLWithPath: "/tmp/research/papers/paper.notes.md")
        )
        XCTAssertEqual(resolved?.path, "/tmp/research/papers/Attention Is All You Need.pdf")

        // Image links must not be treated as clickable PDF citations.
        let imageRange = (doc as NSString).range(of: "fig.png")
        XCTAssertNil(MarkdownCitation.linkAt(utf16Offset: imageRange.location, in: doc))
        XCTAssertNil(MarkdownCitation.resolveTargetURL(for: "https://arxiv.org/abs/1706.03762", relativeTo: notesURL))
        _ = linkStart
    }

    // MARK: - 7. 5-Zone Center Replacement & Observer Cleanup

    func testCenterDropReplaceMarkdownPaneGuardsDirtySoleLeaseAndAllowsSharedLease() throws {
        let pdfURL = try writeTempPDF(named: "paper.pdf")
        let mdURL1 = try writeTempMarkdown(named: "note1.md", contents: "# Note 1\n")
        let mdURL2 = try writeTempMarkdown(named: "note2.md", contents: "# Note 2\n")
        let workspace = makeWorkspace()
        defer { workspace.closeAllSessions() }

        guard case .opened = workspace.open(pdfURL) else {
            return XCTFail("Failed to open PDF")
        }

        let tab = workspace.activeTab
        let pdfPaneID = tab.activePaneID

        guard case let .success(mdPane1) = workspace.openMarkdownInSplit(
            url: mdURL1,
            associatedPDFURL: pdfURL,
            in: tab.id,
            adjacentTo: pdfPaneID,
            direction: .right
        ), let mdSession1 = tab.markdownPaneSessions[mdPane1] else {
            return XCTFail("Failed to split Markdown pane")
        }
        XCTAssertTrue(tab.observedPaneIDs.contains(mdPane1))

        // Dirty sole lease blocks center replacement.
        mdSession1.resourceSession.isAutoSaveEnabled = false
        mdSession1.resourceSession.updateContent("# Note 1\nUnsaved\n", from: mdPane1)

        let blockedCheck = workspace.validateDrop(
            on: mdPane1,
            in: tab.id,
            payload: .fileURL(mdURL2),
            zone: .center,
            availableSize: CGSize(width: 1400, height: 900)
        )
        XCTAssertFalse(blockedCheck.isValid)

        if case let .failure(error) = workspace.openMarkdownReplacingPane(
            url: mdURL2,
            associatedPDFURL: pdfURL,
            in: tab.id,
            replacing: mdPane1
        ) {
            XCTAssertEqual(error as? PaneReplaceError, .targetHasUnsavedDocumentChanges)
        } else {
            XCTFail("Expected sole dirty Markdown pane replacement to be refused")
        }

        // Sharing the dirty Markdown resource across a second pane allows replacing the first.
        let mdPaneClone = try workspace.splitPane(paneID: mdPane1, in: tab.id, direction: .bottom)
        XCTAssertTrue(tab.observedPaneIDs.contains(mdPaneClone))

        let allowedCheck = workspace.validateDrop(
            on: mdPane1,
            in: tab.id,
            payload: .fileURL(mdURL2),
            zone: .center,
            availableSize: CGSize(width: 1400, height: 900)
        )
        XCTAssertTrue(allowedCheck.isValid)

        guard case let .success(mdPane2) = workspace.openMarkdownReplacingPane(
            url: mdURL2,
            associatedPDFURL: pdfURL,
            in: tab.id,
            replacing: mdPane1
        ) else {
            return XCTFail("Expected replacement to succeed when another pane still leases the dirty Markdown")
        }

        XCTAssertFalse(tab.observedPaneIDs.contains(mdPane1))
        XCTAssertTrue(tab.observedPaneIDs.contains(mdPane2))
        XCTAssertEqual(tab.markdownPaneSessions[mdPaneClone]?.resourceSession.content, "# Note 1\nUnsaved\n")
        XCTAssertEqual(tab.markdownPaneSessions[mdPane2]?.resourceSession.content, "# Note 2\n")
    }

    func testMoveMarkdownPaneReplacingPDFPaneAcrossTabsPreservesEdits() throws {
        let pdfURL1 = try writeTempPDF(named: "first.pdf")
        let pdfURL2 = try writeTempPDF(named: "second.pdf")
        let mdURL = try writeTempMarkdown(named: "shared.md", contents: "# Shared\n")
        let workspace = makeWorkspace()
        defer { workspace.closeAllSessions() }

        guard case let .opened(tab1ID) = workspace.open(pdfURL1),
              case let .opened(tab2ID) = workspace.open(pdfURL2) else {
            return XCTFail("Failed to open tabs")
        }

        let tab1 = try XCTUnwrap(workspace.session(tabID: tab1ID))
        let tab2 = try XCTUnwrap(workspace.session(tabID: tab2ID))
        let pdfPane1 = tab1.activePaneID
        let pdfPane2 = tab2.activePaneID

        guard case let .success(mdPaneID) = workspace.openMarkdownInSplit(
            url: mdURL,
            associatedPDFURL: pdfURL1,
            in: tab1ID,
            adjacentTo: pdfPane1,
            direction: .right
        ), let mdSession = tab1.markdownPaneSessions[mdPaneID] else {
            return XCTFail("Failed to open Markdown in tab1")
        }

        mdSession.resourceSession.isAutoSaveEnabled = false
        mdSession.resourceSession.updateContent("# Shared\nPending transfer edit\n", from: mdPaneID)

        let movedID = try workspace.movePaneReplacing(
            sourceTabID: tab1ID,
            paneID: mdPaneID,
            toDestinationTabID: tab2ID,
            replacing: pdfPane2
        )

        XCTAssertEqual(movedID, mdPaneID)
        XCTAssertFalse(tab1.observedPaneIDs.contains(mdPaneID))
        XCTAssertFalse(tab2.observedPaneIDs.contains(pdfPane2))
        XCTAssertTrue(tab2.observedPaneIDs.contains(mdPaneID))
        XCTAssertEqual(tab2.activePaneKind, .markdown)
        XCTAssertEqual(tab2.markdownPaneSessions[mdPaneID]?.resourceSession.content, "# Shared\nPending transfer edit\n")
        XCTAssertEqual(tab2.markdownPaneSessions[mdPaneID]?.resourceSession.activeLeaseCount, 1)
    }

    // MARK: - 5. Pool Registration, Observer Cleanup, Save-As Conflict & Citation Routing Regressions

    func testCreatingMarkdownInEmptyWorkspaceRegistersPoolAndCancelsOldPlaceholderObserving() throws {
        let mdURL = directory.url.appendingPathComponent("fresh-note.md")
        let workspace = makeWorkspace()
        defer { workspace.closeAllSessions() }

        let tab = workspace.activeTab
        XCTAssertTrue(tab.isEmptyPlaceholderTab)
        let oldPlaceholderPaneID = tab.activePaneID
        XCTAssertEqual(tab.observedPaneIDs, [oldPlaceholderPaneID])

        let createResult = workspace.createMarkdownNote(
            at: mdURL,
            initialContent: "# Fresh\n\n"
        )
        guard case let .success((tabID, mdPaneID)) = createResult else {
            return XCTFail("Expected empty-workspace Markdown creation to succeed: \(createResult)")
        }

        XCTAssertEqual(tabID, tab.id)
        XCTAssertNotEqual(mdPaneID, oldPlaceholderPaneID)
        XCTAssertEqual(tab.observedPaneIDs, Set(tab.paneEntries.keys))
        XCTAssertFalse(tab.observedPaneIDs.contains(oldPlaceholderPaneID))

        let createdSession = try XCTUnwrap(tab.markdownPaneSessions[mdPaneID]?.resourceSession)
        XCTAssertTrue(workspace.markdownPool.session(for: mdURL) === createdSession)
        XCTAssertEqual(createdSession.activeLeaseCount, 1)

        // Opening the same file into a second split pane must reuse the registered pool session.
        let extraPaneID = PaneID()
        let poolResult = workspace.markdownPool.open(url: mdURL, for: extraPaneID)
        guard case let .success(reusedSession) = poolResult else {
            return XCTFail("Expected pool open to succeed")
        }
        defer { workspace.markdownPool.release(session: reusedSession, for: extraPaneID) }
        XCTAssertTrue(reusedSession === createdSession)
        XCTAssertEqual(createdSession.activeLeaseCount, 2)
    }

    func testSaveMarkdownAsRefusesDestinationOwnedByAnotherActiveSession() throws {
        let url1 = try writeTempMarkdown(named: "note1.md", contents: "# Note 1\n")
        let url2 = try writeTempMarkdown(named: "note2.md", contents: "# Note 2\n")
        let workspace = makeWorkspace()
        defer { workspace.closeAllSessions() }

        guard case let .opened(tab1ID, pane1) = workspace.openMarkdown(url1),
              case let .opened(tab2ID, pane2) = workspace.openMarkdown(url2),
              let session1 = workspace.session(tabID: tab1ID)?.markdownPaneSessions[pane1]?.resourceSession,
              let session2 = workspace.session(tabID: tab2ID)?.markdownPaneSessions[pane2]?.resourceSession else {
            return XCTFail("Expected both Markdown tabs to open")
        }

        session1.isAutoSaveEnabled = false
        session1.updateContent("# Note 1 edited\n", from: pane1)

        let conflictOutcome = workspace.saveMarkdownAs(session1, to: url2, overwrite: true)
        guard case .failed = conflictOutcome else {
            return XCTFail("Expected saveMarkdownAs to refuse overwriting another active pool session: \(conflictOutcome)")
        }
        XCTAssertEqual(session1.fileURL?.resolvingSymlinksInPath().standardizedFileURL,
                       url1.resolvingSymlinksInPath().standardizedFileURL)
        XCTAssertEqual(session2.content, "# Note 2\n")
        XCTAssertEqual(try String(contentsOf: url2, encoding: .utf8), "# Note 2\n")
    }

    func testCitationRoutingPrefersPaperNoteAssociationAndAssociatedPDFURL() throws {
        let pdfURLA = try writeTempPDF(named: "paper-a.pdf")
        let pdfURLB = try writeTempPDF(named: "paper-b.pdf")
        let workspace = makeWorkspace()
        defer { workspace.closeAllSessions() }

        guard case .opened = workspace.open(pdfURLA) else {
            return XCTFail("Failed to open A.pdf")
        }
        let tab = workspace.activeTab
        let pdfPaneA = tab.activePaneID

        guard case let .success(pdfPaneB) = workspace.openPDFInSplit(
            url: pdfURLB,
            in: tab.id,
            adjacentTo: pdfPaneA,
            direction: .right
        ) else {
            return XCTFail("Failed to open B.pdf in split")
        }

        let createdA = try workspace.noteAssociationStore.createDefaultNote(
            forPDF: pdfURLA,
            initialContent: "# Paper A\n"
        )
        guard case let .success(mdPaneA) = workspace.openOrActivateMarkdownSession(
            createdA.session,
            associatedPDFURL: pdfURLA,
            in: tab.id,
            preferredSplitFrom: pdfPaneA,
            direction: .right
        ), let mdSessionA = tab.markdownPaneSessions[mdPaneA] else {
            return XCTFail("Failed to open Paper A note")
        }

        // B.pdf must NOT hijack Paper A's note just because mdSessionA is the active Markdown pane in the tab.
        XCTAssertNil(workspace.citationTargetMarkdownPane(forPDF: pdfURLB, in: tab.id))

        // Companion PDF resolution from mdSessionA must return Paper A even when Paper B is active.
        tab.activePaneID = pdfPaneB
        XCTAssertEqual(tab.primaryPDFPaneSession?.id, pdfPaneB)
        XCTAssertEqual(workspace.companionPDFPane(for: mdSessionA, in: tab.id)?.id, pdfPaneA)

        // With Paper B's own note also open in the tab, each PDF routes to its own note regardless of focus.
        let createdB = try workspace.noteAssociationStore.createDefaultNote(
            forPDF: pdfURLB,
            initialContent: "# Paper B\n"
        )
        guard case let .success(mdPaneB) = workspace.openOrActivateMarkdownSession(
            createdB.session,
            associatedPDFURL: pdfURLB,
            in: tab.id,
            preferredSplitFrom: pdfPaneB,
            direction: .bottom
        ), let mdSessionB = tab.markdownPaneSessions[mdPaneB] else {
            return XCTFail("Failed to open Paper B note")
        }

        tab.activePaneID = mdPaneB
        XCTAssertEqual(workspace.citationTargetMarkdownPane(forPDF: pdfURLA, in: tab.id)?.id, mdPaneA)
        XCTAssertEqual(workspace.citationTargetMarkdownPane(forPDF: pdfURLB, in: tab.id)?.id, mdPaneB)
        XCTAssertEqual(workspace.companionPDFPane(for: mdSessionA, in: tab.id)?.id, pdfPaneA)
        XCTAssertEqual(workspace.companionPDFPane(for: mdSessionB, in: tab.id)?.id, pdfPaneB)
    }

    func testCitationInsertionGuardsReadOnlyMarkdownSession() throws {
        let mdURL = try writeTempMarkdown(named: "readonly-note.md", contents: "# Locked\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: mdURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: mdURL.path) }

        let workspace = makeWorkspace()
        defer { workspace.closeAllSessions() }

        guard case let .opened(tabID, mdPaneID) = workspace.openMarkdown(mdURL),
              let mdSession = workspace.session(tabID: tabID)?.markdownPaneSessions[mdPaneID] else {
            return XCTFail("Expected read-only Markdown file to open")
        }

        XCTAssertTrue(mdSession.resourceSession.isReadOnlyAtOpen)
        XCTAssertFalse(workspace.canInsertCitation(into: mdSession))
        XCTAssertFalse(workspace.insertCitationText("[Paper, p. 1](./paper.pdf#page=1)", into: mdSession))
        XCTAssertEqual(mdSession.resourceSession.content, "# Locked\n")
        XCTAssertFalse(mdSession.resourceSession.hasUnsavedChanges)
    }
}
