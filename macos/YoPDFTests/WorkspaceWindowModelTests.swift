import AppKit
import PDFKit
import XCTest
@testable import YoPDFCore

@MainActor
final class WorkspaceWindowModelTests: XCTestCase {

    private func makeDocumentDirty(_ model: PDFDocumentModel) throws {
        let document = try XCTUnwrap(model.document)
        let page = try XCTUnwrap(document.page(at: 0))
        let text = try XCTUnwrap(page.string)
        let selection = try XCTUnwrap(document.selection(
            from: page,
            atCharacterIndex: 0,
            to: page,
            atCharacterIndex: min(text.count, 5)
        ))
        model.updateSelection(selection)
        XCTAssertNotNil(model.addMarkup(.highlight))
    }

    func testOpenCreatesIsolatedTabsAndDuplicateOpenActivatesExistingTab() throws {
        let firstURL = try PDFFixtureFactory.writeTemporaryPDF(named: "workspace-first")
        let secondURL = try PDFFixtureFactory.writeTemporaryPDF(named: "workspace-second")
        let badURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-invalid-\(UUID().uuidString).pdf")
        try Data("not a PDF".utf8).write(to: badURL)
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: badURL)
        }

        let workspace = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })
        let initialTabID = workspace.activeTabID
        guard case let .opened(firstTabID) = workspace.open(firstURL) else {
            return XCTFail("The first PDF should load in the initial empty tab.")
        }
        XCTAssertEqual(firstTabID, initialTabID)
        let firstModel = workspace.activeTab.model
        firstModel.goToPage(2)
        firstModel.zoomIn()
        firstModel.zoomIn()
        let firstZoom = firstModel.zoomScale
        let firstTab = workspace.activeTab
        firstTab.searchSession.search("fixture", in: firstModel.document)
        XCTAssertEqual(firstTab.searchSession.inputQuery, "fixture")

        guard case let .opened(secondTabID) = workspace.open(secondURL) else {
            return XCTFail("A second PDF should create a new tab.")
        }
        XCTAssertNotEqual(secondTabID, firstTabID)
        XCTAssertEqual(workspace.tabs.count, 2)
        let secondModel = workspace.activeTab.model
        secondModel.goToPage(1)
        secondModel.zoomIn()
        let secondZoom = secondModel.zoomScale
        XCTAssertNotEqual(firstZoom, secondZoom)

        guard case let .activatedExisting(existingTabID) = workspace.open(firstURL) else {
            return XCTFail("Reopening a PDF in the same window should select its existing tab.")
        }
        XCTAssertEqual(existingTabID, firstTabID)
        XCTAssertEqual(workspace.activePaneID, workspace.activeTab.paneID)
        XCTAssertTrue(workspace.activeTab.model === firstModel)
        XCTAssertEqual(firstModel.currentPageIndex, 2)
        XCTAssertEqual(firstModel.zoomScale, firstZoom)
        XCTAssertEqual(firstTab.searchSession.inputQuery, "fixture")
        XCTAssertEqual(secondModel.currentPageIndex, 1)
        XCTAssertEqual(secondModel.zoomScale, secondZoom)
        XCTAssertEqual(workspace.tabs.count, 2)

        workspace.activate(tabID: secondTabID)
        if case .failed = workspace.open(badURL) {
            XCTAssertEqual(workspace.activeTabID, secondTabID)
            XCTAssertEqual(workspace.tabs.count, 2)
            XCTAssertEqual(workspace.activeTab.model.fileURL, secondURL)
        } else {
            XCTFail("An invalid PDF must fail without replacing an open tab.")
        }

        workspace.closeAllSessions()
    }

    func testNoteDraftAndSessionObjectsSurviveTabSwitchAndCloseCleansSession() throws {
        let firstURL = try PDFFixtureFactory.writeTemporaryPDF(named: "workspace-draft-first")
        let secondURL = try PDFFixtureFactory.writeTemporaryPDF(named: "workspace-draft-second")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }

        let workspace = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })
        guard case let .opened(firstID) = workspace.open(firstURL),
              let page = workspace.activeTab.model.document?.page(at: 0),
              let draft = workspace.activeTab.model.pageNoteDraft(
                at: CGPoint(x: 300, y: 400), on: page
              )
        else {
            return XCTFail("The first PDF should provide a note draft anchor.")
        }
        let firstTab = workspace.activeTab
        XCTAssertTrue(firstTab.composerStore.begin(
            mode: .create(draft),
            anchorRect: .zero,
            pageLabel: "1",
            excerpt: nil,
            contents: "",
            paper: .honey
        ))
        firstTab.composerStore.session?.contents = "Keep this unfinished note"

        guard case let .opened(secondID) = workspace.open(secondURL) else {
            return XCTFail("A second PDF should create another tab.")
        }
        workspace.activate(tabID: firstID)

        XCTAssertTrue(workspace.activeTab === firstTab)
        XCTAssertTrue(workspace.activeTab.composerStore.hasUncommittedChanges)
        XCTAssertEqual(
            workspace.activeTab.composerStore.session?.contents,
            "Keep this unfinished note"
        )
        XCTAssertEqual(workspace.activeTab.model.documentSession?.url, firstURL)

        XCTAssertTrue(workspace.closeTab(tabID: secondID))
        XCTAssertEqual(workspace.activeTabID, firstID)
        XCTAssertFalse(workspace.closeTab(tabID: firstID), "The final tab closes with its window.")

        workspace.discardAllDrafts()
        workspace.closeAllSessions()
    }

    func testUnsavedWorkIncludesDirtyInactiveTabs() throws {
        let firstURL = try PDFFixtureFactory.writeTemporaryPDF(named: "workspace-dirty-first")
        let secondURL = try PDFFixtureFactory.writeTemporaryPDF(named: "workspace-dirty-second")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }

        let workspace = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })
        guard case let .opened(firstID) = workspace.open(firstURL),
              let firstDocument = workspace.activeTab.model.document,
              let firstPage = firstDocument.page(at: 0),
              let firstText = firstPage.string,
              let selection = firstDocument.selection(
                from: firstPage,
                atCharacterIndex: 0,
                to: firstPage,
                atCharacterIndex: min(firstText.count, 5)
              )
        else {
            return XCTFail("The first PDF should contain selectable text.")
        }
        workspace.activeTab.model.updateSelection(selection)
        XCTAssertNotNil(workspace.activeTab.model.addMarkup(.highlight))
        XCTAssertTrue(workspace.activeTab.model.hasUnsavedChanges)

        guard case .opened = workspace.open(secondURL),
              let secondPage = workspace.activeTab.model.document?.page(at: 0),
              let draft = workspace.activeTab.model.pageNoteDraft(
                at: CGPoint(x: 300, y: 400), on: secondPage
              )
        else {
            return XCTFail("The second PDF should load and provide a note anchor.")
        }
        let secondTab = workspace.activeTab
        guard secondTab.composerStore.begin(
            mode: .create(draft),
            anchorRect: .zero,
            pageLabel: "1",
            excerpt: nil,
            contents: "",
            paper: .honey
        ), let draftSession = secondTab.composerStore.session else {
            return XCTFail("The second tab should accept a new note draft.")
        }
        draftSession.contents = "A draft in a background tab"

        workspace.activate(tabID: firstID)
        let work = workspace.unsavedWork

        XCTAssertEqual(workspace.activeTabID, firstID)
        XCTAssertTrue(workspace.activeTab.model.hasUnsavedChanges)
        XCTAssertFalse(workspace.activeTab.composerStore.hasUncommittedChanges)
        XCTAssertTrue(work.documentHasChanges)
        XCTAssertTrue(work.draftHasChanges, "the draft remains protected in the inactive tab")
        XCTAssertTrue(work.hasChanges)

        workspace.discardAllDrafts()
        workspace.discardAllDocumentChanges()
        workspace.closeAllSessions()
    }

    func testCloseTabPromptAndDiscardStayBoundToRequestedBackgroundSession() throws {
        let firstURL = try PDFFixtureFactory.writeTemporaryPDF(named: "workspace-close-first")
        let secondURL = try PDFFixtureFactory.writeTemporaryPDF(named: "workspace-close-second")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }

        let workspace = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })
        guard case let .opened(firstID) = workspace.open(firstURL) else {
            return XCTFail("The first PDF should load.")
        }
        let firstModel = workspace.activeTab.model
        try makeDocumentDirty(firstModel)

        guard case let .opened(secondID) = workspace.open(secondURL),
              let secondPage = workspace.activeTab.model.document?.page(at: 0),
              let draft = workspace.activeTab.model.pageNoteDraft(
                at: CGPoint(x: 300, y: 400), on: secondPage
              )
        else {
            return XCTFail("The second PDF should load and provide a note anchor.")
        }
        let secondTab = try XCTUnwrap(workspace.session(tabID: secondID))
        try makeDocumentDirty(secondTab.model)
        XCTAssertTrue(secondTab.composerStore.begin(
            mode: .create(draft),
            anchorRect: .zero,
            pageLabel: "1",
            excerpt: nil,
            contents: "",
            paper: .honey
        ))
        secondTab.composerStore.session?.contents = "Discard only this tab"

        workspace.activate(tabID: firstID)
        XCTAssertTrue(firstModel.hasUnsavedChanges)
        XCTAssertEqual(workspace.closeTabPrompt(tabID: secondID), .draft)

        XCTAssertTrue(workspace.discardDraft(tabID: secondID))
        XCTAssertEqual(workspace.closeTabPrompt(tabID: secondID), .document)
        XCTAssertTrue(workspace.discardDocumentChanges(tabID: secondID))
        XCTAssertTrue(workspace.closeTab(tabID: secondID))

        XCTAssertTrue(firstModel.hasUnsavedChanges, "discarding B must not abandon A's edits")
        XCTAssertNotNil(firstModel.document)
        XCTAssertNil(workspace.session(tabID: secondID))
        XCTAssertEqual(workspace.activeTabID, firstID)
        workspace.closeAllSessions()
    }

    func testClosingCleanBackgroundTabDoesNotPromptForActiveDirtyDocument() throws {
        let firstURL = try PDFFixtureFactory.writeTemporaryPDF(named: "workspace-clean-close-first")
        let secondURL = try PDFFixtureFactory.writeTemporaryPDF(named: "workspace-clean-close-second")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }

        let workspace = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })
        guard case let .opened(firstID) = workspace.open(firstURL) else {
            return XCTFail("The first PDF should load.")
        }
        let firstModel = workspace.activeTab.model
        try makeDocumentDirty(firstModel)

        guard case let .opened(secondID) = workspace.open(secondURL) else {
            return XCTFail("The second PDF should load.")
        }
        let secondModel = workspace.activeTab.model
        workspace.activate(tabID: firstID)

        XCTAssertTrue(firstModel.hasUnsavedChanges)
        XCTAssertFalse(secondModel.hasUnsavedChanges)
        XCTAssertEqual(try XCTUnwrap(workspace.closeTabPrompt(tabID: secondID)), ReaderPrompt.none)
        XCTAssertTrue(workspace.closeTab(tabID: secondID))

        XCTAssertTrue(firstModel.hasUnsavedChanges, "Closing clean B must leave A's edits intact.")
        XCTAssertNil(workspace.session(tabID: secondID))
        XCTAssertEqual(workspace.activeTabID, firstID)
        workspace.closeAllSessions()
    }

    func testSidebarNavigationStateIsIsolatedWhenPDFGenerationsMatch() throws {
        let firstURL = try PDFFixtureFactory.writeTemporaryPDF(named: "workspace-sidebar-first")
        let secondURL = try PDFFixtureFactory.writeTemporaryPDF(named: "workspace-sidebar-second")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }

        let workspace = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })
        guard case let .opened(firstID) = workspace.open(firstURL) else {
            return XCTFail("The first PDF should load.")
        }
        let firstTab = workspace.activeTab
        let firstModel = firstTab.model
        let firstNavigation = firstTab.navigationState
        XCTAssertTrue(firstNavigation.prepare(for: firstModel.loadGeneration))

        let outlineItem = OutlineSidebarItem(
            id: "first-outline",
            outline: PDFOutline(),
            title: "First document outline",
            depth: 0,
            childCount: 1,
            destination: nil,
            destinationPageIndex: nil,
            isExpanded: false
        )
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 20, height: 20),
            forType: .highlight,
            withProperties: nil
        )
        firstNavigation.outlineItems = [outlineItem]
        firstNavigation.annotationItems = [
            SidebarAnnotationItem(id: "first-annotation", pageIndex: 0, annotation: annotation)
        ]
        firstNavigation.selectedSection = .outline
        firstNavigation.isVisible = false
        firstNavigation.updateMemory {
            $0.markOutlineLoaded()
            $0.selectOutlineItem("first-outline")
            $0.setOutlineItem("first-outline", expanded: false)
            $0.markAnnotationIndexUpdated(revision: firstModel.annotationRevision)
        }

        guard case let .opened(secondID) = workspace.open(secondURL) else {
            return XCTFail("The second PDF should load into another tab.")
        }
        let secondModel = workspace.activeTab.model
        let secondNavigation = workspace.activeTab.navigationState
        XCTAssertEqual(firstModel.loadGeneration, secondModel.loadGeneration)
        XCTAssertTrue(secondNavigation.prepare(for: secondModel.loadGeneration))

        XCTAssertFalse(firstNavigation === secondNavigation)
        XCTAssertTrue(secondNavigation.outlineItems.isEmpty)
        XCTAssertTrue(secondNavigation.annotationItems.isEmpty)
        XCTAssertTrue(secondNavigation.memory.needsOutlineLoad)
        XCTAssertTrue(secondNavigation.memory.needsAnnotationIndex(for: secondModel.annotationRevision))
        XCTAssertNil(secondNavigation.memory.selectedOutlineItemID)
        XCTAssertTrue(secondNavigation.isVisible)
        XCTAssertEqual(secondNavigation.selectedSection, .thumbnails)

        XCTAssertEqual(firstNavigation.outlineItems.map(\.id), ["first-outline"])
        XCTAssertEqual(firstNavigation.annotationItems.map(\.id), ["first-annotation"])
        XCTAssertTrue(firstNavigation.memory.hasLoadedOutline)
        XCTAssertEqual(firstNavigation.memory.selectedOutlineItemID, "first-outline")
        XCTAssertFalse(firstNavigation.isVisible)
        XCTAssertEqual(firstNavigation.selectedSection, .outline)

        workspace.activate(tabID: firstID)
        workspace.activate(tabID: secondID)
        XCTAssertTrue(workspace.activeTab.navigationState === secondNavigation)
        workspace.closeAllSessions()
    }

    func testAdjacentTabShortcutsCycleThroughWorkspaceSessions() {
        let workspace = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })
        let firstID = workspace.activeTabID
        let firstModel = workspace.activeTab.model
        let secondID = workspace.createTab()
        let thirdID = workspace.createTab()

        XCTAssertEqual(workspace.tabs.map(\.id), [firstID, secondID, thirdID])
        XCTAssertEqual(workspace.activeTabID, thirdID, "A new tab becomes the active tab.")

        // ⇧⌘] wraps from the rightmost tab back to the leftmost one, with the
        // reader's focused document following the selection.
        workspace.activateAdjacentTab(direction: .next)
        XCTAssertEqual(workspace.activeTabID, firstID)
        XCTAssertTrue(workspace.activeTab.model === firstModel)

        // ⇧⌘[ wraps from the leftmost tab back to the rightmost one.
        workspace.activateAdjacentTab(direction: .previous)
        XCTAssertEqual(workspace.activeTabID, thirdID)

        // Holding the shortcut down keeps cycling rather than stopping at an
        // end or selecting an out-of-range index.
        for expected in [secondID, firstID, thirdID, secondID] {
            workspace.activateAdjacentTab(direction: .previous)
            XCTAssertEqual(workspace.activeTabID, expected)
        }
        XCTAssertEqual(workspace.tabs.count, 3, "Navigation must never create or close tabs.")

        workspace.closeAllSessions()
    }

    func testAdjacentTabShortcutWithSingleTabKeepsItsSession() {
        let workspace = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })
        let onlyID = workspace.activeTabID
        let session = workspace.activeTab

        workspace.activateAdjacentTab(direction: .previous)
        workspace.activateAdjacentTab(direction: .next)

        XCTAssertEqual(workspace.activeTabID, onlyID)
        XCTAssertTrue(workspace.activeTab === session)
        workspace.closeAllSessions()
    }

    /// Menu shortcuts reach one window through focused scene values. This
    /// covers the model half of that isolation: two workspaces own independent
    /// tab orders and selections, so cycling in the front window cannot move
    /// the selection of a background one.
    func testAdjacentTabNavigationIsScopedToItsOwnWorkspace() {
        let frontWindow = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })
        let backgroundWindow = WorkspaceWindowModel(modelFactory: { PDFDocumentModel() })
        let backgroundFirstID = backgroundWindow.activeTabID
        _ = backgroundWindow.createTab()
        let backgroundActiveID = backgroundWindow.activeTabID

        _ = frontWindow.createTab()
        _ = frontWindow.createTab()
        let frontActiveID = frontWindow.activeTabID
        frontWindow.activateAdjacentTab(direction: .next)     // wraps to the leftmost
        frontWindow.activateAdjacentTab(direction: .previous) // wraps back

        XCTAssertEqual(frontWindow.tabs.count, 3)
        XCTAssertEqual(frontWindow.activeTabID, frontActiveID)
        XCTAssertEqual(backgroundWindow.tabs.count, 2, "Navigation must not add tabs to another window.")
        XCTAssertEqual(
            backgroundWindow.activeTabID,
            backgroundActiveID,
            "Only the focused workspace's tab selection may change."
        )
        XCTAssertNotEqual(backgroundFirstID, backgroundActiveID)

        // The other window still cycles through its own ordered tabs.
        backgroundWindow.activateAdjacentTab(direction: .next)
        XCTAssertEqual(backgroundWindow.activeTabID, backgroundFirstID)

        frontWindow.closeAllSessions()
        backgroundWindow.closeAllSessions()
    }
}
