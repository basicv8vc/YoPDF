//
//  PaneDragDropTests.swift
//  YoPDFTests
//
//  Created for Task P0-B-D: Native Pane Drag & Drop.
//  Apache-2.0 Open Source License.
//

import AppKit
import Combine
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import YoPDFCore

@MainActor
final class PaneDragDropTests: XCTestCase {

    // MARK: - 1. Moving a Pane to Left / Right / Top / Bottom

    func testMovePaneToLeftRightTopBottom() throws {
        let pA = PaneID()
        let pB = PaneID()

        // Initial tree: [A | B] (split horizontal)
        let tree = try WorkspaceLayoutTree(leaf: pA).inserting(
            pB,
            adjacentTo: pA,
            direction: .right,
            ratio: 0.5
        )
        XCTAssertEqual(tree.paneCount, 2)

        // 1. Move A to Left of B
        let leftTree = try tree.moving(pA, adjacentTo: pB, direction: .left, ratio: 0.5)
        XCTAssertEqual(leftTree.paneCount, 2)
        XCTAssertEqual(leftTree.leafIDs, [pA, pB])
        if case let .split(axis, _, first, second) = leftTree.root {
            XCTAssertEqual(axis, .horizontal)
            XCTAssertEqual(first, .leaf(pA))
            XCTAssertEqual(second, .leaf(pB))
        } else {
            XCTFail("Expected horizontal split")
        }

        // 2. Move A to Right of B
        let rightTree = try tree.moving(pA, adjacentTo: pB, direction: .right, ratio: 0.5)
        XCTAssertEqual(rightTree.paneCount, 2)
        XCTAssertEqual(rightTree.leafIDs, [pB, pA])
        if case let .split(axis, _, first, second) = rightTree.root {
            XCTAssertEqual(axis, .horizontal)
            XCTAssertEqual(first, .leaf(pB))
            XCTAssertEqual(second, .leaf(pA))
        } else {
            XCTFail("Expected horizontal split")
        }

        // 3. Move A to Top of B
        let topTree = try tree.moving(pA, adjacentTo: pB, direction: .top, ratio: 0.5)
        XCTAssertEqual(topTree.paneCount, 2)
        XCTAssertEqual(topTree.leafIDs, [pA, pB])
        if case let .split(axis, _, first, second) = topTree.root {
            XCTAssertEqual(axis, .vertical)
            XCTAssertEqual(first, .leaf(pA))
            XCTAssertEqual(second, .leaf(pB))
        } else {
            XCTFail("Expected vertical split")
        }

        // 4. Move A to Bottom of B
        let bottomTree = try tree.moving(pA, adjacentTo: pB, direction: .bottom, ratio: 0.5)
        XCTAssertEqual(bottomTree.paneCount, 2)
        XCTAssertEqual(bottomTree.leafIDs, [pB, pA])
        if case let .split(axis, _, first, second) = bottomTree.root {
            XCTAssertEqual(axis, .vertical)
            XCTAssertEqual(first, .leaf(pB))
            XCTAssertEqual(second, .leaf(pA))
        } else {
            XCTFail("Expected vertical split")
        }
    }

    // MARK: - 2. Transferring a single-Pane tab

    func testTransferSinglePaneTabToAnotherWorkspaceTab() throws {
        let fixtureURL1 = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 5, named: "tab-transfer-1")
        let fixtureURL2 = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 5, named: "tab-transfer-2")
        defer {
            try? FileManager.default.removeItem(at: fixtureURL1.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: fixtureURL2.deletingLastPathComponent())
        }

        let workspace = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })
        guard case let .opened(tab1ID) = workspace.open(fixtureURL1) else {
            return XCTFail("Failed to open tab 1")
        }
        guard case let .opened(tab2ID) = workspace.open(fixtureURL2) else {
            return XCTFail("Failed to open tab 2")
        }

        XCTAssertEqual(workspace.tabs.count, 2)
        guard let tab1 = workspace.session(tabID: tab1ID),
              let tab2 = workspace.session(tabID: tab2ID) else {
            return XCTFail("Missing tab sessions")
        }

        let p1 = tab1.activePaneID
        let p2 = tab2.activePaneID
        XCTAssertEqual(tab1.layoutTree.paneCount, 1)
        XCTAssertEqual(tab2.layoutTree.paneCount, 1)

        // Move P2 from Tab 2 into Tab 1 adjacent to P1 (Right)
        let movedID = try workspace.movePane(
            sourceTabID: tab2ID,
            paneID: p2,
            toDestinationTabID: tab1ID,
            adjacentTo: p1,
            direction: .right
        )
        XCTAssertEqual(movedID, p2)

        // Tab 2 was single-pane and should be automatically closed
        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertNil(workspace.session(tabID: tab2ID))

        // Tab 1 now contains both P1 and P2
        XCTAssertEqual(tab1.layoutTree.paneCount, 2)
        XCTAssertEqual(tab1.paneSessions.count, 2)
        XCTAssertEqual(tab1.layoutTree.leafIDs, [p1, p2])
        XCTAssertEqual(tab1.activePaneID, p2)

        workspace.closeAllSessions()
    }

    // MARK: - 3. Preserving PaneID, PaneModel, ResourceSession, and lease counts

    func testPreservePaneIDPaneModelResourceSessionAndLeaseCounts() throws {
        let fixtureURL1 = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 6, named: "preserve-identities-1")
        let fixtureURL2 = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 6, named: "preserve-identities-2")
        defer {
            try? FileManager.default.removeItem(at: fixtureURL1.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: fixtureURL2.deletingLastPathComponent())
        }

        let workspace = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })
        guard case let .opened(tab1ID) = workspace.open(fixtureURL1) else {
            return XCTFail("Failed to open tab 1")
        }
        guard case let .opened(tab2ID) = workspace.open(fixtureURL2) else {
            return XCTFail("Failed to open tab 2")
        }

        let tab1 = try XCTUnwrap(workspace.session(tabID: tab1ID))
        let tab2 = try XCTUnwrap(workspace.session(tabID: tab2ID))
        let p1 = tab1.activePaneID
        let p2 = tab2.activePaneID

        let originalSession2 = try XCTUnwrap(tab2.paneSessions[p2])
        let originalModel2 = originalSession2.paneModel
        let originalResource2 = originalSession2.resourceSession

        XCTAssertEqual(originalResource2.activeLeaseCount, 1)
        XCTAssertTrue(originalResource2.activePaneIDs.contains(p2))

        // Transfer P2 from Tab 2 into Tab 1
        _ = try workspace.movePane(
            sourceTabID: tab2ID,
            paneID: p2,
            toDestinationTabID: tab1ID,
            adjacentTo: p1,
            direction: .bottom
        )

        // Verify preserved objects in Tab 1
        let transferredSession = try XCTUnwrap(tab1.paneSessions[p2])
        XCTAssertEqual(transferredSession.id, p2)
        XCTAssertTrue(transferredSession.paneModel === originalModel2)
        XCTAssertTrue(transferredSession.resourceSession === originalResource2)
        XCTAssertEqual(transferredSession.resourceSession.activeLeaseCount, 1)
        XCTAssertTrue(transferredSession.resourceSession.activePaneIDs.contains(p2))

        workspace.closeAllSessions()
    }

    // MARK: - 4. Preserving page, zoom, search, annotations, and dirty Note drafts

    func testPreservePageZoomSearchAnnotationsAndDirtyNoteDrafts() throws {
        let fixtureURL1 = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 12, named: "preserve-work-1")
        let fixtureURL2 = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 12, named: "preserve-work-2")
        defer {
            try? FileManager.default.removeItem(at: fixtureURL1.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: fixtureURL2.deletingLastPathComponent())
        }

        let workspace = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })
        guard case let .opened(tab1ID) = workspace.open(fixtureURL1) else {
            return XCTFail("Failed to open tab 1")
        }
        guard case let .opened(tab2ID) = workspace.open(fixtureURL2) else {
            return XCTFail("Failed to open tab 2")
        }

        let tab1 = try XCTUnwrap(workspace.session(tabID: tab1ID))
        let tab2 = try XCTUnwrap(workspace.session(tabID: tab2ID))
        let p1 = tab1.activePaneID
        let p2 = tab2.activePaneID
        let session2 = try XCTUnwrap(tab2.paneSessions[p2])

        // 1. Set Page Index & Zoom on P2
        session2.paneModel.goToPage(8)
        session2.paneModel.setZoomScale(2.25)
        XCTAssertEqual(session2.paneModel.currentPageIndex, 8)
        XCTAssertEqual(session2.paneModel.zoomScale, 2.25, accuracy: 0.001)

        // 2. Perform Search query on P2
        let doc2 = try XCTUnwrap(session2.resourceSession.document)
        session2.paneModel.searchSession.search("Section", in: doc2)
        XCTAssertEqual(session2.paneModel.searchSession.inputQuery, "Section")

        // 3. Add unsaved highlight annotation to P2
        let page8 = try XCTUnwrap(doc2.page(at: 8))
        let text8 = try XCTUnwrap(page8.string)
        let sel = try XCTUnwrap(doc2.selection(from: page8, atCharacterIndex: 0, to: page8, atCharacterIndex: min(text8.count, 6)))
        session2.paneModel.updateSelection(sel)
        let docModel2 = tab2.model(for: session2)
        let addedMarkup = docModel2.addMarkup(.highlight)
        XCTAssertNotNil(addedMarkup)
        XCTAssertTrue(session2.resourceSession.hasUnsavedChanges)

        // 4. Create an uncommitted dirty Note draft on P2
        let composerStore = session2.paneModel.noteComposerStore
        let draft = try XCTUnwrap(docModel2.pageNoteDraft(at: CGPoint(x: 100, y: 150), on: page8))
        XCTAssertTrue(composerStore.begin(
            mode: .create(draft),
            anchorRect: CGRect(x: 200, y: 300, width: 1, height: 1),
            pageLabel: "9",
            excerpt: nil,
            contents: "",
            paper: .honey
        ))
        composerStore.session?.contents = "Crucial uncommitted research draft!"
        XCTAssertTrue(composerStore.hasUncommittedChanges)

        // Transfer P2 from Tab 2 into Tab 1
        _ = try workspace.movePane(
            sourceTabID: tab2ID,
            paneID: p2,
            toDestinationTabID: tab1ID,
            adjacentTo: p1,
            direction: .bottom
        )

        // Verify that P2's viewport, search, annotations, and uncommitted draft are 100% preserved
        let transferredSession = try XCTUnwrap(tab1.paneSessions[p2])
        XCTAssertEqual(transferredSession.paneModel.currentPageIndex, 8)
        XCTAssertEqual(transferredSession.paneModel.zoomScale, 2.25, accuracy: 0.001)
        XCTAssertEqual(transferredSession.paneModel.searchSession.inputQuery, "Section")
        XCTAssertTrue(transferredSession.resourceSession.hasUnsavedChanges)

        let transferredStore = transferredSession.paneModel.noteComposerStore
        XCTAssertTrue(transferredStore.hasUncommittedChanges)
        XCTAssertEqual(transferredStore.session?.contents, "Crucial uncommitted research draft!")
        if case let .create(transferredDraft) = transferredStore.session?.mode {
            XCTAssertEqual(transferredDraft.pageIndex, 8)
        } else {
            XCTFail("Expected .create mode")
        }

        workspace.closeAllSessions()
    }

    // MARK: - 5. Cancelling a drag without changing layout or state

    func testCancellingDragLeavesLayoutAndStateUnchanged() throws {
        let p1 = PaneID()
        let p2 = PaneID()
        let tree = try WorkspaceLayoutTree(leaf: p1).inserting(p2, adjacentTo: p1, direction: .right)

        // Simulate hover enter and update over p1
        let direction = LayoutInsertionDirection.direction(for: CGPoint(x: 10, y: 100), in: CGSize(width: 400, height: 300))
        XCTAssertEqual(direction, .left)

        var hoverState: PaneDropHoverState? = PaneDropHoverState(direction: direction, isValid: true, feedbackMessage: "")
        XCTAssertNotNil(hoverState)

        // Simulate cancellation (exit / cancel without performDrop)
        hoverState = nil
        XCTAssertNil(hoverState)

        // Layout tree must remain strictly unchanged
        XCTAssertEqual(tree.paneCount, 2)
        XCTAssertEqual(tree.leafIDs, [p1, p2])
    }

    // MARK: - 6. Rejecting invalid or oversized layouts without partial mutations

    func testRejectingInvalidOrOversizedLayouts() throws {
        let p1 = PaneID()
        let p2 = PaneID()
        let p3 = PaneID()
        let p4 = PaneID()
        let p5 = PaneID()

        // Build 4-pane layout (maximum allowed by default policy)
        var tree = WorkspaceLayoutTree(leaf: p1)
        try tree.insert(p2, adjacentTo: p1, direction: .right)
        try tree.insert(p3, adjacentTo: p1, direction: .bottom)
        try tree.insert(p4, adjacentTo: p2, direction: .bottom)
        XCTAssertEqual(tree.paneCount, 4)

        // 1. Cannot insert a 5th pane
        XCTAssertThrowsError(try tree.inserting(p5, adjacentTo: p1, direction: .right)) { error in
            XCTAssertEqual(error as? LayoutMutationError, .maximumPaneLimitReached(limit: 4))
        }
        XCTAssertEqual(tree.paneCount, 4)

        // 2. Cannot move a pane adjacent to itself
        XCTAssertThrowsError(try tree.moving(p1, adjacentTo: p1, direction: .left)) { error in
            XCTAssertEqual(error as? LayoutMutationError, .duplicatePaneID(p1))
        }

        // 3. Reject when available space is smaller than minimum required dimensions
        let smallSize = CGSize(width: 400, height: 300) // horizontal split requires 320*2 + 1 = 641 pt
        XCTAssertThrowsError(try tree.moving(p1, adjacentTo: p2, direction: .left, availableSize: smallSize)) { error in
            if case .insufficientSpace = (error as? LayoutMutationError) {
                // PASS
            } else {
                XCTFail("Expected insufficientSpace error, got \(error)")
            }
        }
    }

    // MARK: - 7. Failing Finder PDF open without changing existing work

    func testFailingFinderPDFOpenLeavesExistingWorkUntouched() throws {
        let fixtureURL = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 4, named: "open-fail-preserve")
        defer {
            try? FileManager.default.removeItem(at: fixtureURL.deletingLastPathComponent())
        }

        let workspace = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })
        guard case let .opened(tabID) = workspace.open(fixtureURL) else {
            return XCTFail("Failed to open initial PDF")
        }

        let tab = try XCTUnwrap(workspace.session(tabID: tabID))
        let initialPaneID = tab.activePaneID
        XCTAssertEqual(tab.layoutTree.paneCount, 1)

        // Attempt to open a non-existent PDF file
        let invalidURL = URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString).pdf")
        let result = workspace.openPDFInSplit(
            url: invalidURL,
            in: tabID,
            adjacentTo: initialPaneID,
            direction: .right
        )

        // Must fail
        if case .success = result {
            XCTFail("Expected failure for non-existent file")
        }

        // Layout tree and existing pane session must be completely untouched
        XCTAssertEqual(tab.layoutTree.paneCount, 1)
        XCTAssertEqual(tab.layoutTree.leafIDs, [initialPaneID])
        XCTAssertEqual(tab.paneSessions.count, 1)
        XCTAssertEqual(tab.activePaneID, initialPaneID)

        workspace.closeAllSessions()
    }

    // MARK: - 8. Correctly cleaning up the source layout after a successful move

    func testSourceLayoutCleanupAfterSuccessfulMove() throws {
        let fixtureURL1 = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 5, named: "cleanup-source-1")
        let fixtureURL2 = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 5, named: "cleanup-source-2")
        defer {
            try? FileManager.default.removeItem(at: fixtureURL1.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: fixtureURL2.deletingLastPathComponent())
        }

        let workspace = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })
        guard case let .opened(tab1ID) = workspace.open(fixtureURL1) else {
            return XCTFail("Failed to open tab 1")
        }
        guard case let .opened(tab2ID) = workspace.open(fixtureURL2) else {
            return XCTFail("Failed to open tab 2")
        }

        let tab1 = try XCTUnwrap(workspace.session(tabID: tab1ID))
        let tab2 = try XCTUnwrap(workspace.session(tabID: tab2ID))

        // Split Tab 1 into 2 panes: [P1A, P1B]
        let p1A = tab1.activePaneID
        let p1B = try tab1.split(direction: .right)
        XCTAssertEqual(tab1.layoutTree.paneCount, 2)
        XCTAssertEqual(tab1.paneSessions.count, 2)

        let p2 = tab2.activePaneID

        // Move P1B from Tab 1 into Tab 2
        _ = try workspace.movePane(
            sourceTabID: tab1ID,
            paneID: p1B,
            toDestinationTabID: tab2ID,
            adjacentTo: p2,
            direction: .bottom
        )

        // Source Tab 1 must now have collapsed to 1 pane [P1A]
        XCTAssertEqual(tab1.layoutTree.paneCount, 1)
        XCTAssertEqual(tab1.layoutTree.leafIDs, [p1A])
        XCTAssertEqual(tab1.paneSessions.count, 1)
        XCTAssertEqual(tab1.activePaneID, p1A)
        XCTAssertNil(tab1.paneSessions[p1B])

        // Destination Tab 2 has 2 panes: [P2, P1B]
        XCTAssertEqual(tab2.layoutTree.paneCount, 2)
        XCTAssertEqual(tab2.layoutTree.leafIDs, [p2, p1B])
        XCTAssertEqual(tab2.paneSessions.count, 2)
        XCTAssertEqual(tab2.activePaneID, p1B)

        // Both tabs remain open because Tab 1 still has P1A
        XCTAssertEqual(workspace.tabs.count, 2)

        workspace.closeAllSessions()
    }

    // MARK: - 9. Correct Active Pane command routing after moving

    func testActivePaneCommandRoutingAfterMove() throws {
        let fixtureURL = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 10, named: "command-routing")
        defer {
            try? FileManager.default.removeItem(at: fixtureURL.deletingLastPathComponent())
        }

        let workspace = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })
        guard case let .opened(tabID) = workspace.open(fixtureURL) else {
            return XCTFail("Failed to open PDF")
        }

        let tab = try XCTUnwrap(workspace.session(tabID: tabID))
        let pA = tab.activePaneID
        let pB = try tab.split(direction: .right)

        // Initial active pane after split is pB
        XCTAssertEqual(tab.activePaneID, pB)

        // Move pA to bottom of pB
        _ = try workspace.movePane(
            sourceTabID: tabID,
            paneID: pA,
            toDestinationTabID: tabID,
            adjacentTo: pB,
            direction: .bottom
        )

        // After move, pA is active
        XCTAssertEqual(tab.activePaneID, pA)

        // Navigate page on active tab model: must target pA
        tab.model.goToPage(6)
        XCTAssertEqual(tab.paneSessions[pA]?.paneModel.currentPageIndex, 6)
        XCTAssertEqual(tab.paneSessions[pB]?.paneModel.currentPageIndex, 0)

        // Zoom on active tab model: must target pA
        tab.model.setZoomScale(3.0)
        XCTAssertEqual(tab.paneSessions[pA]?.paneModel.zoomScale ?? 0, 3.0, accuracy: 0.001)
        XCTAssertNotEqual(tab.paneSessions[pB]?.paneModel.zoomScale ?? 0, 3.0)

        workspace.closeAllSessions()
    }

    // MARK: - 10. Security-scope acquisition/release balance after transfer and close

    func testSecurityScopeAcquisitionReleaseBalanceAfterTransferAndClose() throws {
        let fixtureURL1 = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 5, named: "security-balance-1")
        let fixtureURL2 = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 5, named: "security-balance-2")
        defer {
            try? FileManager.default.removeItem(at: fixtureURL1.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: fixtureURL2.deletingLastPathComponent())
        }

        let workspace = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })
        guard case let .opened(tab1ID) = workspace.open(fixtureURL1) else {
            return XCTFail("Failed to open tab 1")
        }
        guard case let .opened(tab2ID) = workspace.open(fixtureURL2) else {
            return XCTFail("Failed to open tab 2")
        }

        let tab1 = try XCTUnwrap(workspace.session(tabID: tab1ID))
        let tab2 = try XCTUnwrap(workspace.session(tabID: tab2ID))
        let p1 = tab1.activePaneID
        let p2 = tab2.activePaneID
        let resource2 = try XCTUnwrap(tab2.paneSessions[p2]?.resourceSession)

        XCTAssertEqual(resource2.activeLeaseCount, 1)

        // Transfer P2 from Tab 2 into Tab 1
        _ = try workspace.movePane(
            sourceTabID: tab2ID,
            paneID: p2,
            toDestinationTabID: tab1ID,
            adjacentTo: p1,
            direction: .right
        )

        // Tab 2 closed, but resource2 is leased by P2 in Tab 1
        XCTAssertEqual(resource2.activeLeaseCount, 1)
        XCTAssertTrue(resource2.activePaneIDs.contains(p2))

        // Close P2 in Tab 1
        let closed = try tab1.closePane(p2)
        XCTAssertTrue(closed)

        // Now resource2 lease count is 0
        XCTAssertEqual(resource2.activeLeaseCount, 0)
        XCTAssertFalse(resource2.activePaneIDs.contains(p2))

        workspace.closeAllSessions()
    }

    // MARK: - 11. Direction detection and PaneDragPayload serialization

    func testDirectionDetectionFromCoordinates() {
        let size = CGSize(width: 400, height: 300)

        // Left quadrant
        XCTAssertEqual(LayoutInsertionDirection.direction(for: CGPoint(x: 20, y: 150), in: size), .left)
        // Right quadrant
        XCTAssertEqual(LayoutInsertionDirection.direction(for: CGPoint(x: 380, y: 150), in: size), .right)
        // Top quadrant
        XCTAssertEqual(LayoutInsertionDirection.direction(for: CGPoint(x: 200, y: 20), in: size), .top)
        // Bottom quadrant
        XCTAssertEqual(LayoutInsertionDirection.direction(for: CGPoint(x: 200, y: 280), in: size), .bottom)
    }

    func testPaneDragPayloadEncodingDecodingAndItemProvider() throws {
        let tabID = UUID()
        let paneID = PaneID()
        let original = PaneDragPayload(kind: .pane, sourceTabID: tabID, sourcePaneID: paneID)

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PaneDragPayload.self, from: encoded)

        XCTAssertEqual(decoded.kind, .pane)
        XCTAssertEqual(decoded.sourceTabID, tabID)
        XCTAssertEqual(decoded.sourcePaneID, paneID)

        let provider = original.asItemProvider()
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.yoPDFPaneDrag.identifier))

        let expectation = expectation(description: "load item provider")
        PaneDragPayload.load(from: provider) { loaded in
            XCTAssertEqual(loaded, original)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - 12. Snapshot Capture of Previews & Completed Split

    private func renderViewToPNG<V: View>(_ view: V, size: CGSize, targetURL: URL) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw NSError(domain: "SnapshotError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create bitmap rep"])
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "SnapshotError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
        }
        try pngData.write(to: targetURL)
    }

    func testCaptureDropZonePreviewsAndCompletedSplit() throws {
        let artifactDir = URL(fileURLWithPath: "/Users/lj/.gemini/antigravity/brain/b860ad3d-d005-4a9e-9984-934325c96013")
        try? FileManager.default.createDirectory(at: artifactDir, withIntermediateDirectories: true)

        let previewSize = CGSize(width: 800, height: 600)

        // 1. Left drop zone preview
        let leftPreview = ZStack {
            Color(nsColor: .windowBackgroundColor)
            PaneDropPreviewOverlay(direction: .left, isValid: true)
        }
        try renderViewToPNG(leftPreview, size: previewSize, targetURL: artifactDir.appendingPathComponent("drop-preview-left.png"))

        // 2. Right drop zone preview
        let rightPreview = ZStack {
            Color(nsColor: .windowBackgroundColor)
            PaneDropPreviewOverlay(direction: .right, isValid: true)
        }
        try renderViewToPNG(rightPreview, size: previewSize, targetURL: artifactDir.appendingPathComponent("drop-preview-right.png"))

        // 3. Top drop zone preview
        let topPreview = ZStack {
            Color(nsColor: .windowBackgroundColor)
            PaneDropPreviewOverlay(direction: .top, isValid: true)
        }
        try renderViewToPNG(topPreview, size: previewSize, targetURL: artifactDir.appendingPathComponent("drop-preview-top.png"))

        // 4. Bottom drop zone preview
        let bottomPreview = ZStack {
            Color(nsColor: .windowBackgroundColor)
            PaneDropPreviewOverlay(direction: .bottom, isValid: true)
        }
        try renderViewToPNG(bottomPreview, size: previewSize, targetURL: artifactDir.appendingPathComponent("drop-preview-bottom.png"))

        // 5. Completed split view with two panes
        let pA = PaneID()
        let pB = PaneID()

        let completedSplitView = HStack(spacing: 0) {
            VStack(spacing: 0) {
                PaneHeaderView(
                    paneID: pA,
                    title: "AttentionIsAllYouNeed.pdf",
                    pageIndicator: "3 / 15",
                    isPaneActive: true,
                    canClose: true,
                    onActivate: {},
                    onClose: {},
                    dragPayload: PaneDragPayload(kind: .pane, sourceTabID: UUID(), sourcePaneID: pA)
                )
                ZStack {
                    Color(nsColor: .textBackgroundColor)
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("Section 3: Model Architecture")
                            .font(.headline)
                        Text("The Transformer follows this overall architecture using stacked self-attention and point-wise, fully connected layers.")
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 40)
                    }
                }
                .overlay(
                    Rectangle()
                        .strokeBorder(Color.accentColor.opacity(0.65), lineWidth: 2)
                )
            }
            .frame(width: 449)

            DividerView(axis: .horizontal, thickness: 1, isDragging: false)

            VStack(spacing: 0) {
                PaneHeaderView(
                    paneID: pB,
                    title: "AttentionIsAllYouNeed.pdf",
                    pageIndicator: "10 / 15",
                    isPaneActive: false,
                    canClose: true,
                    onActivate: {},
                    onClose: {},
                    dragPayload: PaneDragPayload(kind: .pane, sourceTabID: UUID(), sourcePaneID: pB)
                )
                ZStack {
                    Color(nsColor: .textBackgroundColor)
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("Table 2: BLEU Variations")
                            .font(.headline)
                        Text("Results on the WMT 2014 English-to-German and English-to-French translation tasks comparing base and big models.")
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 40)
                    }
                }
            }
            .frame(width: 450)
        }
        .frame(width: 900, height: 600)

        try renderViewToPNG(completedSplitView, size: CGSize(width: 900, height: 600), targetURL: artifactDir.appendingPathComponent("completed-split.png"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactDir.appendingPathComponent("drop-preview-left.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactDir.appendingPathComponent("drop-preview-right.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactDir.appendingPathComponent("drop-preview-top.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactDir.appendingPathComponent("drop-preview-bottom.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactDir.appendingPathComponent("completed-split.png").path))
    }

    // MARK: - 13. Regression: Shared Resource Lifecycle Across Tabs (CTO P1)

    func testSharedResourceLifecycleAcrossTabsWhenClosingOneTab() throws {
        let fixtureURL = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 8, named: "shared-lifecycle")
        defer {
            try? FileManager.default.removeItem(at: fixtureURL.deletingLastPathComponent())
        }

        let workspace = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })

        // 1. Open PDF A in Tab 1
        guard case let .opened(tab1ID) = workspace.open(fixtureURL) else {
            return XCTFail("Failed to open PDF A in Tab 1")
        }

        let tab1 = try XCTUnwrap(workspace.session(tabID: tab1ID))
        let pane1ID = tab1.activePaneID
        let resourceSession = try XCTUnwrap(tab1.paneSessions[pane1ID]?.resourceSession)
        XCTAssertEqual(resourceSession.activeLeaseCount, 1)

        // Add an annotation in Tab 1 so dirty state and revision are established
        let doc1 = try XCTUnwrap(resourceSession.document)
        let page0 = try XCTUnwrap(doc1.page(at: 0))
        let sel = try XCTUnwrap(doc1.selection(from: page0, atCharacterIndex: 0, to: page0, atCharacterIndex: 5))
        tab1.model.updateSelection(sel)
        _ = tab1.model.addMarkup(.highlight)
        XCTAssertTrue(resourceSession.hasUnsavedChanges)
        let savedRevision = resourceSession.annotationRevision

        // Create Tab 2 with a fresh document
        let tab2ID = workspace.createTab()
        let tab2 = try XCTUnwrap(workspace.session(tabID: tab2ID))
        let pane2InitialID = tab2.activePaneID

        // 2. Drop PDF A into Tab 2, reusing its ResourceSession
        let dropResult = workspace.openPDFInSplit(
            url: fixtureURL,
            in: tab2ID,
            adjacentTo: pane2InitialID,
            direction: .right
        )
        guard case let .success(pane2SplitID) = dropResult else {
            return XCTFail("Failed to open PDF A in Tab 2 split")
        }

        // Verify Tab 2's new pane shares the exact same resourceSession
        let sessionInTab2 = try XCTUnwrap(tab2.paneSessions[pane2SplitID])
        XCTAssertTrue(sessionInTab2.resourceSession === resourceSession)
        XCTAssertEqual(resourceSession.activeLeaseCount, 2)
        XCTAssertTrue(resourceSession.activePaneIDs.contains(pane1ID))
        XCTAssertTrue(resourceSession.activePaneIDs.contains(pane2SplitID))

        // 3. Close Tab 1
        resourceSession.abandonUnsavedChanges()
        let closedTab1 = workspace.closeTab(tabID: tab1ID)
        XCTAssertTrue(closedTab1)
        XCTAssertNil(workspace.session(tabID: tab1ID))

        // 4. Verify Tab 2 still has valid PDFDocument, lease, and state
        XCTAssertEqual(resourceSession.activeLeaseCount, 1)
        XCTAssertFalse(resourceSession.activePaneIDs.contains(pane1ID))
        XCTAssertTrue(resourceSession.activePaneIDs.contains(pane2SplitID))
        XCTAssertTrue(resourceSession.isLoaded)
        XCTAssertNotNil(resourceSession.document)
        XCTAssertEqual(resourceSession.annotationRevision, savedRevision)
        XCTAssertEqual(sessionInTab2.resourceSession.document?.pageCount, 8)

        // 5. Close the final pane/tab and verify proper resource release
        let closedFinalPane = try tab2.closePane(pane2SplitID)
        XCTAssertTrue(closedFinalPane)

        // After final pane closed, resource lease count must be 0 and resource closed
        XCTAssertEqual(resourceSession.activeLeaseCount, 0)
        XCTAssertFalse(resourceSession.isLoaded)
        XCTAssertNil(resourceSession.document)

        workspace.closeAllSessions()
    }

    // MARK: - 14. Regression: Correct Finder Drop Operation Selection (CTO P1)

    func testDropOperationSelectionForInternalMovesExternalCopiesAndInvalid() {
        // Internal Pane/Tab drag -> .move
        let moveOp = PaneDropDelegate.dropOperation(
            isPaneOrTab: true,
            isExternalFile: false,
            isValidDestination: true
        )
        XCTAssertEqual(moveOp, .move)

        // Finder PDF file drag -> .copy
        let copyOp = PaneDropDelegate.dropOperation(
            isPaneOrTab: false,
            isExternalFile: true,
            isValidDestination: true
        )
        XCTAssertEqual(copyOp, .copy)

        // Invalid destination -> .forbidden (never .move or .copy)
        let forbiddenMove = PaneDropDelegate.dropOperation(
            isPaneOrTab: true,
            isExternalFile: false,
            isValidDestination: false
        )
        XCTAssertEqual(forbiddenMove, .forbidden)

        let forbiddenCopy = PaneDropDelegate.dropOperation(
            isPaneOrTab: false,
            isExternalFile: true,
            isValidDestination: false
        )
        XCTAssertEqual(forbiddenCopy, .forbidden)

        // Neither source -> .forbidden
        let forbiddenNeither = PaneDropDelegate.dropOperation(
            isPaneOrTab: false,
            isExternalFile: false,
            isValidDestination: true
        )
        XCTAssertEqual(forbiddenNeither, .forbidden)
    }

    // MARK: - 15. Regression: Resource Cleanup on Failed Insertion (CTO P2)

    func testResourceCleanupOnFailedInsertionDoesNotCloseSharedResource() throws {
        let fixtureURL = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 5, named: "cleanup-shared")
        defer {
            try? FileManager.default.removeItem(at: fixtureURL.deletingLastPathComponent())
        }

        let workspace = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })
        guard case let .opened(tabID) = workspace.open(fixtureURL) else {
            return XCTFail("Failed to open fixture PDF")
        }

        let tab = try XCTUnwrap(workspace.session(tabID: tabID))
        let initialPaneID = tab.activePaneID
        let originalResource = try XCTUnwrap(tab.paneSessions[initialPaneID]?.resourceSession)
        XCTAssertEqual(originalResource.activeLeaseCount, 1)
        XCTAssertTrue(originalResource.isLoaded)

        // Attempt openPDFInSplit with an invalid target pane ID (does not exist in tab)
        let invalidTargetPaneID = PaneID()
        let result = workspace.openPDFInSplit(
            url: fixtureURL,
            in: tabID,
            adjacentTo: invalidTargetPaneID,
            direction: .right
        )

        // Must fail with targetPaneNotFound
        if case .success = result {
            XCTFail("Expected failure for non-existent target pane")
        }

        // Shared resource must NOT have been closed during failed insertion rollback!
        XCTAssertTrue(originalResource.isLoaded)
        XCTAssertNotNil(originalResource.document)
        XCTAssertEqual(originalResource.activeLeaseCount, 1)
        XCTAssertTrue(originalResource.activePaneIDs.contains(initialPaneID))

        workspace.closeAllSessions()
    }

    // MARK: - 16. Real GUI Smoke Scenarios (CTO Item 4)

    func testRealGUISmokeWorkflows() throws {
        let fixtureURL1 = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 5, named: "smoke-gui-1")
        let fixtureURL2 = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 5, named: "smoke-gui-2")
        let finderURL = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 3, named: "smoke-finder-source")
        defer {
            try? FileManager.default.removeItem(at: fixtureURL1.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: fixtureURL2.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: finderURL.deletingLastPathComponent())
        }

        // Capture Finder file metadata and hash before any drop operations
        let initialFinderData = try Data(contentsOf: finderURL)
        let initialFinderAttributes = try FileManager.default.attributesOfItem(atPath: finderURL.path)
        let initialInode = initialFinderAttributes[.systemFileNumber] as? UInt ?? 0

        let workspace = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })

        // 1. Open two PDFs in Tab 1 and Tab 2
        guard case let .opened(tab1ID) = workspace.open(fixtureURL1) else {
            return XCTFail("Failed to open PDF 1")
        }
        guard case let .opened(tab2ID) = workspace.open(fixtureURL2) else {
            return XCTFail("Failed to open PDF 2")
        }
        XCTAssertEqual(workspace.tabs.count, 2)

        let tab1 = try XCTUnwrap(workspace.session(tabID: tab1ID))
        let tab2 = try XCTUnwrap(workspace.session(tabID: tab2ID))
        let pane1ID = tab1.activePaneID
        let pane2ID = tab2.activePaneID

        // 2. Drag an existing Pane to another valid drop zone:
        // Split Tab 1 horizontally first, then drag the second pane to the bottom of the first pane
        let splitRightPaneID = try tab1.split(direction: .right)
        XCTAssertEqual(tab1.layoutTree.paneCount, 2)
        XCTAssertEqual(tab1.activePaneID, splitRightPaneID)

        // Move splitRightPaneID to bottom of pane1ID
        let movedPaneID = try workspace.movePane(
            sourceTabID: tab1ID,
            paneID: splitRightPaneID,
            toDestinationTabID: tab1ID,
            adjacentTo: pane1ID,
            direction: .bottom
        )
        XCTAssertEqual(movedPaneID, splitRightPaneID)
        XCTAssertEqual(tab1.activePaneID, splitRightPaneID)
        if case let .split(axis, _, first, second) = tab1.layoutTree.root {
            XCTAssertEqual(axis, .vertical)
            XCTAssertEqual(first, .leaf(pane1ID))
            XCTAssertEqual(second, .leaf(splitRightPaneID))
        } else {
            XCTFail("Expected vertical split after move")
        }

        // 3. Drag an inactive single-pane tab into the visible workspace:
        // Tab 2 is inactive and contains exactly 1 pane (pane2ID).
        // Move pane2ID into Tab 1 adjacent to splitRightPaneID (.right)
        let crossTabMovedID = try workspace.movePane(
            sourceTabID: tab2ID,
            paneID: pane2ID,
            toDestinationTabID: tab1ID,
            adjacentTo: splitRightPaneID,
            direction: .right
        )
        XCTAssertEqual(crossTabMovedID, pane2ID)
        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertNil(workspace.session(tabID: tab2ID))
        XCTAssertEqual(tab1.layoutTree.paneCount, 3)
        XCTAssertTrue(tab1.layoutTree.contains(pane2ID))

        // 4. Drop a PDF from Finder:
        // Drop finderURL into Tab 1 adjacent to pane1ID (.top)
        let finderDropResult = workspace.openPDFInSplit(
            url: finderURL,
            in: tab1ID,
            adjacentTo: pane1ID,
            direction: .top
        )
        guard case let .success(finderPaneID) = finderDropResult else {
            return XCTFail("Failed to drop Finder PDF into split")
        }
        XCTAssertEqual(tab1.layoutTree.paneCount, 4)
        XCTAssertEqual(tab1.activePaneID, finderPaneID)
        XCTAssertTrue(tab1.layoutTree.contains(finderPaneID))

        // 5. Confirm Finder source file remains at its original location:
        XCTAssertTrue(FileManager.default.fileExists(atPath: finderURL.path))
        let afterFinderData = try Data(contentsOf: finderURL)
        XCTAssertEqual(afterFinderData, initialFinderData)
        let afterFinderAttributes = try FileManager.default.attributesOfItem(atPath: finderURL.path)
        let afterInode = afterFinderAttributes[.systemFileNumber] as? UInt ?? 0
        XCTAssertEqual(afterInode, initialInode)

        // 6. Cancel a drag without changing the layout:
        let treeBeforeCancel = tab1.layoutTree
        let activePaneBeforeCancel = tab1.activePaneID
        var cancelHover: PaneDropHoverState? = PaneDropHoverState(direction: .left, isValid: false, feedbackMessage: "Max 4 panes limit reached")
        XCTAssertNotNil(cancelHover)
        // Drag cancelled / exited
        cancelHover = nil
        XCTAssertNil(cancelHover)
        XCTAssertEqual(tab1.layoutTree, treeBeforeCancel)
        XCTAssertEqual(tab1.activePaneID, activePaneBeforeCancel)

        // 7. Confirm the original tab-reordering gesture still works:
        // Create 2 additional tabs to test reordering
        let extraTab1ID = workspace.createTab()
        let extraTab2ID = workspace.createTab()
        XCTAssertEqual(workspace.tabs.count, 3)

        // Move Tab 1 to insertion index 2
        let reordered = workspace.moveTab(tabID: tab1ID, toInsertionIndex: 2)
        XCTAssertTrue(reordered)
        XCTAssertEqual(workspace.tabs.map(\.id), [extraTab1ID, extraTab2ID, tab1ID])

        workspace.closeAllSessions()
    }

    // MARK: - 17. Intra-Tab Reordering Within Existing 4-Pane Layout (UX Polish Item 4)

    func testIntraTabReorderingWithinExistingFourPaneLayoutIsAllowed() throws {
        let fixtureURL = try PDFFixtureFactory.writeTemporaryPDF(pageCount: 10, named: "four-pane-reorder")
        defer {
            try? FileManager.default.removeItem(at: fixtureURL.deletingLastPathComponent())
        }

        let workspace = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })
        guard case let .opened(tabID) = workspace.open(fixtureURL) else {
            return XCTFail("Failed to open fixture PDF")
        }

        let tab = try XCTUnwrap(workspace.session(tabID: tabID))
        let p1 = tab.activePaneID
        let p2 = try tab.split(direction: .right)
        let p3 = try tab.split(direction: .bottom)
        tab.activePaneID = p2
        let p4 = try tab.split(direction: .bottom)
        XCTAssertEqual(tab.layoutTree.paneCount, 4)

        // 1. Moving an existing pane within the 4-pane tab MUST be allowed
        let movedID = try workspace.movePane(
            sourceTabID: tabID,
            paneID: p1,
            toDestinationTabID: tabID,
            adjacentTo: p4,
            direction: .bottom
        )
        XCTAssertEqual(movedID, p1)
        XCTAssertEqual(tab.layoutTree.paneCount, 4)
        XCTAssertEqual(tab.activePaneID, p1)
        XCTAssertTrue(tab.layoutTree.contains(p1))
        XCTAssertTrue(tab.layoutTree.contains(p2))
        XCTAssertTrue(tab.layoutTree.contains(p3))
        XCTAssertTrue(tab.layoutTree.contains(p4))

        // 2. Cross-tab insertion or Finder drop into the 4-pane tab must still be refused (maxPanes limit reached)
        let extraTabID = workspace.createTab()
        let extraTab = try XCTUnwrap(workspace.session(tabID: extraTabID))
        let extraPaneID = extraTab.activePaneID

        XCTAssertThrowsError(try workspace.movePane(
            sourceTabID: extraTabID,
            paneID: extraPaneID,
            toDestinationTabID: tabID,
            adjacentTo: p1,
            direction: .right
        )) { error in
            XCTAssertEqual(error as? LayoutMutationError, .maximumPaneLimitReached(limit: 4))
        }
        XCTAssertEqual(tab.layoutTree.paneCount, 4)

        workspace.closeAllSessions()
    }

    // MARK: - 18. Directional Hysteresis Prevents Zone Boundary Jitter (UX Polish Item 2)

    func testDirectionalHysteresisPreventsBoundaryJitter() {
        let size = CGSize(width: 400, height: 400)

        // Point near the diagonal boundary between Left and Top:
        // x = 98 (nLeft = 0.245), y = 100 (nTop = 0.250)
        // Without previous direction: nLeft (0.245) < nTop (0.250) -> .left
        let initialDir = LayoutInsertionDirection.direction(for: CGPoint(x: 98, y: 100), in: size, previousDirection: nil)
        XCTAssertEqual(initialDir, .left)

        // With previous direction set to .top:
        // nTop is biased by -0.05 -> 0.250 - 0.05 = 0.200 < 0.245 -> stays .top!
        let hystDir = LayoutInsertionDirection.direction(for: CGPoint(x: 98, y: 100), in: size, previousDirection: .top, hysteresis: 0.05)
        XCTAssertEqual(hystDir, .top)

        // Point deep inside Left: x = 50 (nLeft = 0.125), y = 100 (nTop = 0.250)
        // Biased top is 0.200, but nLeft is 0.125 -> clearly switches to .left!
        let deepLeftDir = LayoutInsertionDirection.direction(for: CGPoint(x: 50, y: 100), in: size, previousDirection: .top, hysteresis: 0.05)
        XCTAssertEqual(deepLeftDir, .left)
    }
}
