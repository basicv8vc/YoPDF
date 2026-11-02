import AppKit
import XCTest
@testable import YoPDFCore

@MainActor
final class WorkspaceWindowModelTests: XCTestCase {

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
}
