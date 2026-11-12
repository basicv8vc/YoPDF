//
//  MultiPaneWorkspaceTests.swift
//  YoPDFTests
//
//  Created for Task P0-B-C: Multi-Pane UI Integration.
//  Apache-2.0 Open Source License.
//

import AppKit
import PDFKit
import XCTest
@testable import YoPDFCore

@MainActor
final class MultiPaneWorkspaceTests: XCTestCase {

    // MARK: - 1. Split Right / Down creates actual panes

    func testSplitRightAndDownCreatesActualPanes() throws {
        let fixtureURL = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 10, named: "multipane-split")
        defer {
            try? FileManager.default.removeItem(at: fixtureURL.deletingLastPathComponent())
        }

        let workspace = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })
        guard case .opened = workspace.open(fixtureURL) else {
            return XCTFail("Failed to open fixture PDF")
        }

        let tab = workspace.activeTab
        let initialPaneID = tab.activePaneID
        XCTAssertEqual(tab.layoutTree.paneCount, 1)
        XCTAssertEqual(tab.paneSessions.count, 1)

        // Split Right
        let rightPaneID = try workspace.splitActivePane(direction: .right)
        XCTAssertEqual(tab.layoutTree.paneCount, 2)
        XCTAssertEqual(tab.paneSessions.count, 2)
        XCTAssertEqual(tab.activePaneID, rightPaneID)
        XCTAssertTrue(tab.layoutTree.contains(initialPaneID))
        XCTAssertTrue(tab.layoutTree.contains(rightPaneID))

        guard case let .split(axis, ratio, first, second) = tab.layoutTree.root else {
            return XCTFail("Expected split node at root")
        }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(ratio, 0.5, accuracy: 0.001)
        XCTAssertEqual(first, .leaf(initialPaneID))
        XCTAssertEqual(second, .leaf(rightPaneID))

        // Split Down on the right pane
        let bottomPaneID = try workspace.splitActivePane(direction: .bottom)
        XCTAssertEqual(tab.layoutTree.paneCount, 3)
        XCTAssertEqual(tab.paneSessions.count, 3)
        XCTAssertEqual(tab.activePaneID, bottomPaneID)
        XCTAssertTrue(tab.layoutTree.contains(bottomPaneID))

        workspace.closeAllSessions()
    }

    // MARK: - 2. Two panes share same PDFDocument and PDFResourceSession

    func testTwoPanesShareSamePDFDocumentAndResourceSession() throws {
        let fixtureURL = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 5, named: "multipane-share")
        defer {
            try? FileManager.default.removeItem(at: fixtureURL.deletingLastPathComponent())
        }

        let workspace = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })
        guard case .opened = workspace.open(fixtureURL) else {
            return XCTFail("Failed to open fixture PDF")
        }

        let tab = workspace.activeTab
        let paneA = tab.activePaneID
        let paneB = try workspace.splitActivePane(direction: .right)

        guard let sessionA = tab.paneSessions[paneA],
              let sessionB = tab.paneSessions[paneB] else {
            return XCTFail("Missing pane sessions")
        }

        // Must share exact same PDFResourceSession instance
        XCTAssertTrue(sessionA.resourceSession === sessionB.resourceSession)

        // Must share exact same PDFDocument instance
        let docA = try XCTUnwrap(sessionA.resourceSession.document)
        let docB = try XCTUnwrap(sessionB.resourceSession.document)
        XCTAssertTrue(docA === docB)

        // Lease count must be 2
        XCTAssertEqual(sessionA.resourceSession.activeLeaseCount, 2)
        XCTAssertTrue(sessionA.resourceSession.activePaneIDs.contains(paneA))
        XCTAssertTrue(sessionA.resourceSession.activePaneIDs.contains(paneB))

        // Adding highlight via Pane A's document model updates shared document and revision
        let page0 = try XCTUnwrap(docA.page(at: 0))
        let text = try XCTUnwrap(page0.string)
        let sel = try XCTUnwrap(docA.selection(from: page0, atCharacterIndex: 0, to: page0, atCharacterIndex: min(text.count, 4)))
        sessionA.paneModel.updateSelection(sel)

        let initialRev = sessionA.resourceSession.annotationRevision
        let docModelA = tab.model(for: sessionA)
        let added = docModelA.addMarkup(.highlight)
        XCTAssertNotNil(added)

        XCTAssertGreaterThan(sessionB.resourceSession.annotationRevision, initialRev)
        XCTAssertTrue(page0.annotations.contains(where: { MarkupKind(annotation: $0) == .highlight }))

        workspace.closeAllSessions()
    }

    // MARK: - 3. Independent page navigation and zoom

    func testNavigatingOrZoomingPaneADoesNotChangePaneB() throws {
        let fixtureURL = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 10, named: "multipane-nav")
        defer {
            try? FileManager.default.removeItem(at: fixtureURL.deletingLastPathComponent())
        }

        let workspace = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })
        guard case .opened = workspace.open(fixtureURL) else {
            return XCTFail("Failed to open fixture PDF")
        }

        let tab = workspace.activeTab
        let paneA = tab.activePaneID
        let paneB = try workspace.splitActivePane(direction: .right)

        guard let sessionA = tab.paneSessions[paneA],
              let sessionB = tab.paneSessions[paneB] else {
            return XCTFail("Missing pane sessions")
        }

        // Navigate Pane A to page 3 (index 2)
        sessionA.paneModel.goToPage(2)
        // Navigate Pane B to page 8 (index 7)
        sessionB.paneModel.goToPage(7)

        XCTAssertEqual(sessionA.paneModel.currentPageIndex, 2)
        XCTAssertEqual(sessionB.paneModel.currentPageIndex, 7)

        // Zoom Pane A
        sessionA.paneModel.setZoomScale(2.5)
        // Zoom Pane B
        sessionB.paneModel.setZoomScale(0.75)

        XCTAssertEqual(sessionA.paneModel.zoomScale, 2.5, accuracy: 0.001)
        XCTAssertEqual(sessionB.paneModel.zoomScale, 0.75, accuracy: 0.001)

        // Advancing Pane A does not move Pane B
        sessionA.paneModel.goToNextPage()
        XCTAssertEqual(sessionA.paneModel.currentPageIndex, 3)
        XCTAssertEqual(sessionB.paneModel.currentPageIndex, 7)

        // Fitting Pane B does not alter Pane A manual zoom
        sessionB.paneModel.fitToWindow()
        XCTAssertTrue(sessionB.paneModel.isAutoScaling)
        XCTAssertFalse(sessionA.paneModel.isAutoScaling)
        XCTAssertEqual(sessionA.paneModel.zoomScale, 2.5, accuracy: 0.001)

        workspace.closeAllSessions()
    }

    // MARK: - 4. Active Pane changes and commands route to it

    func testActivePaneChangesCorrectlyAndCommandsTargetIt() throws {
        let fixtureURL = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 8, named: "multipane-active")
        defer {
            try? FileManager.default.removeItem(at: fixtureURL.deletingLastPathComponent())
        }

        let workspace = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })
        guard case .opened = workspace.open(fixtureURL) else {
            return XCTFail("Failed to open fixture PDF")
        }

        let tab = workspace.activeTab
        let paneA = tab.activePaneID
        let paneB = try workspace.splitActivePane(direction: .right)

        // Split activates the new pane
        XCTAssertEqual(tab.activePaneID, paneB)
        XCTAssertEqual(workspace.activeLayoutPaneID, paneB)

        // Active model operates on Pane B
        workspace.activeTab.model.goToPage(4)
        XCTAssertEqual(tab.paneSessions[paneB]?.paneModel.currentPageIndex, 4)
        XCTAssertEqual(tab.paneSessions[paneA]?.paneModel.currentPageIndex, 0)

        // Switch active pane to Pane A
        workspace.activate(paneID: paneA)
        XCTAssertEqual(tab.activePaneID, paneA)
        XCTAssertEqual(workspace.activeLayoutPaneID, paneA)

        // Active model operates on Pane A
        workspace.activeTab.model.goToPage(2)
        workspace.activeTab.model.zoomIn()
        let paneAZoom = tab.paneSessions[paneA]!.paneModel.zoomScale

        XCTAssertEqual(tab.paneSessions[paneA]?.paneModel.currentPageIndex, 2)
        XCTAssertEqual(tab.paneSessions[paneB]?.paneModel.currentPageIndex, 4)
        XCTAssertNotEqual(tab.paneSessions[paneB]!.paneModel.zoomScale, paneAZoom)

        workspace.closeAllSessions()
    }

    // MARK: - 5. Closing one pane preserves other pane and shared document

    func testClosingOnePanePreservesOtherPaneAndSharedDocument() throws {
        let fixtureURL = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 5, named: "multipane-close")
        defer {
            try? FileManager.default.removeItem(at: fixtureURL.deletingLastPathComponent())
        }

        let workspace = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })
        guard case .opened = workspace.open(fixtureURL) else {
            return XCTFail("Failed to open fixture PDF")
        }

        let tab = workspace.activeTab
        let paneA = tab.activePaneID
        let paneB = try workspace.splitActivePane(direction: .right)

        let sharedResource = tab.paneSessions[paneA]!.resourceSession
        XCTAssertEqual(sharedResource.activeLeaseCount, 2)

        // Navigate Pane B to page 3
        tab.paneSessions[paneB]?.paneModel.goToPage(3)

        // Close Pane A
        let closed = try workspace.closePane(paneID: paneA)
        XCTAssertTrue(closed)

        // Layout tree now has only Pane B
        XCTAssertEqual(tab.layoutTree.paneCount, 1)
        XCTAssertEqual(tab.activePaneID, paneB)
        XCTAssertNil(tab.paneSessions[paneA])
        XCTAssertNotNil(tab.paneSessions[paneB])

        // Shared resource must remain open and leased by Pane B
        XCTAssertTrue(sharedResource.isLoaded)
        XCTAssertEqual(sharedResource.activeLeaseCount, 1)
        XCTAssertTrue(sharedResource.activePaneIDs.contains(paneB))

        // Pane B preserves its page navigation
        XCTAssertEqual(tab.paneSessions[paneB]?.paneModel.currentPageIndex, 3)

        // Cannot close the only remaining pane
        XCTAssertThrowsError(try workspace.closePane(paneID: paneB)) { error in
            XCTAssertEqual(error as? LayoutMutationError, .cannotCloseOnlyPane)
        }

        workspace.closeAllSessions()
    }

    // MARK: - 6. Invalid splits leave original layout untouched

    func testInvalidSplitsLeaveOriginalLayoutUntouched() throws {
        let fixtureURL = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 5, named: "multipane-policy")
        defer {
            try? FileManager.default.removeItem(at: fixtureURL.deletingLastPathComponent())
        }

        let workspace = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })
        guard case .opened = workspace.open(fixtureURL) else {
            return XCTFail("Failed to open fixture PDF")
        }

        let tab = workspace.activeTab
        _ = tab.activePaneID

        // 1. Split up to maxPanes (4)
        _ = try workspace.splitActivePane(direction: .right)
        _ = try workspace.splitActivePane(direction: .bottom)
        _ = try workspace.splitActivePane(direction: .right)
        XCTAssertEqual(tab.layoutTree.paneCount, 4)

        let treeBefore = tab.layoutTree
        XCTAssertFalse(workspace.canSplit(direction: .right))

        // Attempt 5th split -> throws maximumPaneLimitReached
        XCTAssertThrowsError(try workspace.splitActivePane(direction: .right)) { error in
            guard case .maximumPaneLimitReached(let limit) = error as? LayoutMutationError else {
                return XCTFail("Expected maximumPaneLimitReached error")
            }
            XCTAssertEqual(limit, 4)
        }
        XCTAssertEqual(tab.layoutTree, treeBefore)

        // 2. Insufficient space test
        let freshWorkspace = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })
        guard case .opened = freshWorkspace.open(fixtureURL) else {
            return XCTFail("Failed to open fixture PDF")
        }
        let freshTab = freshWorkspace.activeTab
        let freshTreeBefore = freshTab.layoutTree

        // Try splitting in container smaller than required (e.g. 500pt width < 320*2 + 1 = 641pt)
        let tinySize = CGSize(width: 500, height: 400)
        XCTAssertFalse(freshWorkspace.canSplit(direction: .right, availableSize: tinySize))

        XCTAssertThrowsError(
            try freshWorkspace.splitActivePane(direction: .right, availableSize: tinySize)
        ) { error in
            guard case .insufficientSpace = error as? LayoutMutationError else {
                return XCTFail("Expected insufficientSpace error")
            }
        }
        XCTAssertEqual(freshTab.layoutTree, freshTreeBefore)

        workspace.closeAllSessions()
        freshWorkspace.closeAllSessions()
    }

    // MARK: - 7. Uncommitted Note drafts protected during pane, tab, window close

    func testUncommittedNoteDraftsRemainProtectedDuringPaneTabWindowClose() throws {
        let fixtureURL = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 5, named: "multipane-draft")
        defer {
            try? FileManager.default.removeItem(at: fixtureURL.deletingLastPathComponent())
        }

        let workspace = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })
        guard case .opened = workspace.open(fixtureURL) else {
            return XCTFail("Failed to open fixture PDF")
        }

        let tab = workspace.activeTab
        let paneA = tab.activePaneID
        let paneB = try workspace.splitActivePane(direction: .right)

        guard let sessionB = tab.paneSessions[paneB],
              let page = sessionB.resourceSession.document?.page(at: 0),
              let draft = tab.model(for: sessionB).pageNoteDraft(at: CGPoint(x: 100, y: 100), on: page)
        else {
            return XCTFail("Could not create note draft anchor")
        }

        // Start draft in Pane B
        XCTAssertTrue(sessionB.paneModel.noteComposerStore.begin(
            mode: .create(draft),
            anchorRect: .zero,
            pageLabel: "1",
            excerpt: nil,
            contents: "",
            paper: .honey
        ))
        sessionB.paneModel.noteComposerStore.session?.contents = "Unsaved draft in Pane B"

        // 1. Pane close prompt protects Pane B draft
        let panePrompt = workspace.closePanePrompt(paneID: paneB)
        XCTAssertEqual(panePrompt, .draft)

        // 2. Tab close prompt protects drafts in any pane
        let tabPrompt = workspace.closeTabPrompt(tabID: tab.id)
        XCTAssertEqual(tabPrompt, .draft)

        // 3. Tab close is refused while draft is dirty
        XCTAssertFalse(workspace.closeTab(tabID: tab.id))

        // 4. Window unsavedWork detects draft changes across any pane
        XCTAssertTrue(workspace.unsavedWork.draftHasChanges)

        // Discard draft cleans Pane B
        _ = workspace.discardDraft(tabID: tab.id)
        XCTAssertFalse(sessionB.paneModel.noteComposerStore.hasUncommittedChanges)

        // Now Pane A can be closed cleanly
        XCTAssertTrue(try workspace.closePane(paneID: paneA))

        workspace.closeAllSessions()
    }
}
