import AppKit
import PDFKit
import XCTest
@testable import YoPDFCore

@MainActor
final class PDFResourceSessionTests: XCTestCase {

    nonisolated(unsafe) private var temporaryFiles: [URL] = []

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: url.path
            )
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        temporaryFiles.removeAll()
        super.tearDown()
    }

    // MARK: - 1 & 2: Shared Resource Session and Document

    func testTwoPaneModelsShareSameResourceSessionAndDocument() throws {
        let url = try makeTemporaryPDF(pageCount: 3, named: "shared-doc") { page in
            "Page \(page) Content"
        }
        let resource = PDFResourceSession(access: SecurityScopeSpy())
        XCTAssertTrue(resource.open(url: url))
        let liveDocument = try XCTUnwrap(resource.document)

        let paneA = PDFPaneModel(id: PaneID(), resourceSession: resource)
        let paneB = PDFPaneModel(id: PaneID(), resourceSession: resource)

        XCTAssertTrue(paneA.resourceSession === paneB.resourceSession)
        XCTAssertTrue(paneA.document === paneB.document)
        XCTAssertTrue(paneA.document === liveDocument)
        XCTAssertEqual(resource.activeLeaseCount, 2)
    }

    // MARK: - 3 & 4: Independent Page Navigation and Zoom

    func testIndependentPageNavigationAndZoomState() throws {
        let url = try makeTemporaryPDF(pageCount: 5, named: "independent-nav") { page in
            "Page \(page) Content"
        }
        let resource = PDFResourceSession(access: SecurityScopeSpy())
        XCTAssertTrue(resource.open(url: url))

        let paneA = PDFPaneModel(id: PaneID(), resourceSession: resource)
        let paneB = PDFPaneModel(id: PaneID(), resourceSession: resource)

        // Navigation independence
        paneA.goToPage(2)
        XCTAssertEqual(paneA.currentPageIndex, 2)
        XCTAssertEqual(paneB.currentPageIndex, 0, "Pane B page should not change when Pane A navigates.")

        paneB.goToPage(4)
        XCTAssertEqual(paneB.currentPageIndex, 4)
        XCTAssertEqual(paneA.currentPageIndex, 2, "Pane A page should remain at 2.")

        // Zoom independence
        paneA.setZoomScale(1.8)
        XCTAssertEqual(paneA.zoomScale, 1.8)
        XCTAssertFalse(paneA.isAutoScaling)
        XCTAssertEqual(paneB.zoomScale, 1.0, "Pane B zoom should remain at default 1.0.")
        XCTAssertTrue(paneB.isAutoScaling)

        paneB.setZoomScale(0.75)
        XCTAssertEqual(paneB.zoomScale, 0.75)
        XCTAssertFalse(paneB.isAutoScaling)
        XCTAssertEqual(paneA.zoomScale, 1.8, "Pane A zoom should remain at 1.8.")
    }

    // MARK: - 5: Annotation in Pane A Visible in Pane B

    func testAnnotationCreatedInPaneAIsVisibleInPaneB() throws {
        let url = try makeTemporaryPDF(pageCount: 2, named: "shared-annot") { _ in
            "Sample selectable text for annotation test"
        }
        let resource = PDFResourceSession(access: SecurityScopeSpy())
        XCTAssertTrue(resource.open(url: url))
        let doc = try XCTUnwrap(resource.document)
        let page0 = try XCTUnwrap(doc.page(at: 0))

        let paneA = PDFPaneModel(id: PaneID(), resourceSession: resource)
        let paneB = PDFPaneModel(id: PaneID(), resourceSession: resource)

        let initialRevision = resource.annotationRevision

        let selection = try XCTUnwrap(doc.selection(from: page0, atCharacterIndex: 0, to: page0, atCharacterIndex: 6))
        paneA.updateSelection(selection)
        let summary = paneA.addHighlightToSelection()
        XCTAssertNotNil(summary)

        XCTAssertEqual(page0.annotations.count, 1)
        XCTAssertGreaterThan(resource.annotationRevision, initialRevision)
        XCTAssertEqual(paneB.document?.page(at: 0)?.annotations.count, 1, "Pane B sees the same underlying annotation on page 0.")
    }

    // MARK: - 6: Shared Document-Level Undo/Redo

    func testSharedDocumentLevelUndoRedoAcrossPanes() throws {
        let url = try makeTemporaryPDF(pageCount: 2, named: "shared-undo") { _ in
            "Sample text for undo redo verification"
        }
        let resource = PDFResourceSession(access: SecurityScopeSpy())
        XCTAssertTrue(resource.open(url: url))
        let doc = try XCTUnwrap(resource.document)
        let page0 = try XCTUnwrap(doc.page(at: 0))

        let paneA = PDFPaneModel(id: PaneID(), resourceSession: resource)
        let paneB = PDFPaneModel(id: PaneID(), resourceSession: resource)

        let selection = try XCTUnwrap(doc.selection(from: page0, atCharacterIndex: 0, to: page0, atCharacterIndex: 6))
        paneA.updateSelection(selection)
        XCTAssertNotNil(paneA.addHighlightToSelection())
        XCTAssertEqual(page0.annotations.count, 1)
        XCTAssertTrue(paneA.canUndoMarkup)
        XCTAssertTrue(paneB.canUndoMarkup, "Pane B observes that undo is available on the shared document.")

        // Undo from Pane B
        XCTAssertTrue(paneB.undoMarkup())
        XCTAssertEqual(page0.annotations.count, 0, "Undo from Pane B removed the annotation.")
        XCTAssertTrue(paneA.canRedoMarkup, "Pane A observes that redo is available.")
        XCTAssertTrue(paneB.canRedoMarkup)

        // Redo from Pane A
        XCTAssertTrue(paneA.redoMarkup())
        XCTAssertEqual(page0.annotations.count, 1, "Redo from Pane A restored the annotation.")
    }

    // MARK: - 7: Multiple Edits Schedule One Resource-Level Autosave

    func testMultipleEditsScheduleSingleResourceAutosaveDebounce() async throws {
        let url = try makeTemporaryPDF(pageCount: 2, named: "single-autosave") { _ in
            "Text to edit and trigger debounced autosave"
        }
        let resource = PDFResourceSession(access: SecurityScopeSpy())
        resource.autoSaveDebounceNanoseconds = 50_000_000 // 50ms for test
        XCTAssertTrue(resource.open(url: url))
        let doc = try XCTUnwrap(resource.document)
        let page0 = try XCTUnwrap(doc.page(at: 0))

        let paneA = PDFPaneModel(id: PaneID(), resourceSession: resource)
        let paneB = PDFPaneModel(id: PaneID(), resourceSession: resource)

        let sel1 = try XCTUnwrap(doc.selection(from: page0, atCharacterIndex: 0, to: page0, atCharacterIndex: 4))
        paneA.updateSelection(sel1)
        XCTAssertNotNil(paneA.addHighlightToSelection())
        XCTAssertEqual(resource.autoSaveStatus, .pending)
        let firstGen = resource.autoSaveGeneration

        // Immediate second edit from Pane B
        let sel2 = try XCTUnwrap(doc.selection(from: page0, atCharacterIndex: 5, to: page0, atCharacterIndex: 10))
        paneB.updateSelection(sel2)
        XCTAssertNotNil(paneB.addUnderlineToSelection())
        XCTAssertEqual(resource.autoSaveStatus, .pending)

        XCTAssertGreaterThan(resource.autoSaveGeneration, firstGen, "Debounce task was rescheduled for the single shared resource.")

        // Wait for debounce and write to complete
        while resource.hasUnsavedChanges {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertFalse(resource.hasUnsavedChanges, "Both edits were committed in the single autosave.")
        XCTAssertEqual(resource.autoSaveStatus, .saved)
    }

    // MARK: - 8: Closing Pane A Does Not Release Pane B Lease

    func testClosingPaneADoesNotReleasePaneBResourceLease() throws {
        let url = try makeTemporaryPDF(pageCount: 2, named: "lease-test") { _ in "Content" }
        let resource = PDFResourceSession(access: SecurityScopeSpy())
        XCTAssertTrue(resource.open(url: url))

        let paneA = PDFPaneModel(id: PaneID(), resourceSession: resource)
        let paneB = PDFPaneModel(id: PaneID(), resourceSession: resource)
        XCTAssertEqual(resource.activeLeaseCount, 2)
        XCTAssertNotNil(resource.documentSession)

        paneA.close()
        XCTAssertEqual(resource.activeLeaseCount, 1)
        XCTAssertNotNil(resource.documentSession, "DocumentSession must remain open while Pane B is active.")
        XCTAssertTrue(resource.isLoaded)
        XCTAssertNotNil(paneB.document)
    }

    // MARK: - 9: Closing Final Pane Waits for In-Flight Background Work

    private final class TestGate: @unchecked Sendable {
        private let entered = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        func pause() {
            entered.signal()
            release.wait()
        }
        func waitUntilEntered() {
            entered.wait()
        }
        func signalRelease() {
            release.signal()
        }
    }

    func testClosingFinalPaneWaitsForActiveBackgroundWork() async throws {
        let url = try makeTemporaryPDF(pageCount: 2, named: "wait-on-close") { _ in "Content" }
        let resource = PDFResourceSession(access: SecurityScopeSpy())
        resource.autoSaveDebounceNanoseconds = 10_000_000
        let gate = TestGate()
        resource.autoSaveSerializer = { snapshot in
            gate.pause()
            return PDFDocumentSaveSerializer.dataRepresentationPreservingShuaGroups(in: snapshot.document)
        }
        XCTAssertTrue(resource.open(url: url))
        let doc = try XCTUnwrap(resource.document)
        let page = try XCTUnwrap(doc.page(at: 0))

        let pane = PDFPaneModel(id: PaneID(), resourceSession: resource)
        let sel = try XCTUnwrap(doc.selection(from: page, atCharacterIndex: 0, to: page, atCharacterIndex: 4))
        pane.updateSelection(sel)
        XCTAssertNotNil(pane.addHighlightToSelection())

        // Wait until serializer is entered without blocking main actor
        let enteredTask = Task.detached {
            gate.waitUntilEntered()
        }
        _ = await enteredTask.value

        XCTAssertEqual(resource.autoSaveStatus, .saving)

        let serializerReleaser = Task.detached {
            try? await Task.sleep(nanoseconds: 50_000_000)
            gate.signalRelease()
        }

        pane.close()
        _ = await serializerReleaser.value
        XCTAssertEqual(resource.activeLeaseCount, 0)
        XCTAssertNil(resource.documentSession, "After background work drains, session is safely closed.")
    }

    // MARK: - 10 & 11: Search Serialization & Pane Result Isolation

    func testSearchRequestsFromTwoPanesSerializeAndIsolateResults() async throws {
        let doc = try makeDocument(pageCount: 2) { page in
            page == 0 ? "alpha first page" : "beta second page"
        }
        let coordinator = PDFSearchCoordinator(document: doc)

        let paneA_ID = UUID()
        let paneB_ID = UUID()

        let sessionA = PDFSearchSession(coordinator: coordinator, debounceNanoseconds: 0, paneID: paneA_ID)
        let sessionB = PDFSearchSession(coordinator: coordinator, debounceNanoseconds: 0, paneID: paneB_ID)

        sessionA.search("alpha", in: doc)
        sessionB.search("beta", in: doc)

        let deadline = Date().addingTimeInterval(5)
        while (sessionA.isSearching || sessionB.isSearching) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertFalse(sessionA.isSearching)
        XCTAssertFalse(sessionB.isSearching)

        XCTAssertEqual(sessionA.results.count, 1)
        XCTAssertEqual(sessionA.results.first?.string?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), "alpha")

        XCTAssertEqual(sessionB.results.count, 1)
        XCTAssertEqual(sessionB.results.first?.string?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), "beta")
    }

    func testSearchCancellationDrainsAndExecutesQueuedSearchFromAnotherPane() async throws {
        let doc = try makeDocument(pageCount: 20) { page in
            page == 19 ? "targetterm at end" : String(repeating: "filler ", count: 200)
        }
        let coordinator = PDFSearchCoordinator(document: doc)
        let paneA_ID = UUID()
        let paneB_ID = UUID()

        var matchesA: [PDFSelection] = []
        var completeACalled = false
        var completeBCalled = false
        var matchesB: [PDFSelection] = []

        // Pane A starts a slow search across 20 pages
        coordinator.requestSearch(
            paneID: paneA_ID,
            query: "filler",
            onMatch: { matchesA.append($0) },
            onComplete: { _ in completeACalled = true }
        )
        XCTAssertTrue(coordinator.isFinding)
        XCTAssertEqual(coordinator.activePaneID, paneA_ID)

        // Pane B queues a search for "targetterm"
        coordinator.requestSearch(
            paneID: paneB_ID,
            query: "targetterm",
            onMatch: { matchesB.append($0) },
            onComplete: {
                matchesB = $0
                completeBCalled = true
            }
        )
        XCTAssertEqual(coordinator.queuedCount, 1)

        // Cancel Pane A's search while active
        coordinator.cancelSearch(for: paneA_ID)

        // Wait for cancellation to drain and Pane B to finish
        let deadline = Date().addingTimeInterval(5)
        while coordinator.isFinding && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertFalse(coordinator.isFinding)
        XCTAssertFalse(completeACalled, "Cancelled request must not call onComplete.")
        XCTAssertTrue(completeBCalled, "Queued request must be executed after cancellation drains.")
        XCTAssertEqual(matchesB.count, 1)
        XCTAssertEqual(matchesB.first?.string?.trimmingCharacters(in: .whitespacesAndNewlines), "targetterm")
    }

    func testLateNotificationFromCancelledOperationIsDropped() throws {
        let doc = try makeDocument(pageCount: 2) { _ in "Text" }
        let coordinator = PDFSearchCoordinator(document: doc)
        let paneID = UUID()

        var receivedMatches: [PDFSelection] = []
        var completeCalled = false

        let reqID = coordinator.requestSearch(
            paneID: paneID,
            query: "Text",
            onMatch: { receivedMatches.append($0) },
            onComplete: { _ in completeCalled = true }
        )
        XCTAssertNotNil(reqID)

        // Cancel the search immediately
        coordinator.cancelSearch(for: paneID)

        // Simulate late PDFKit notification arriving after cancellation
        let page = try XCTUnwrap(doc.page(at: 0))
        let fakeSelection = try XCTUnwrap(doc.selection(from: page, atCharacterIndex: 0, to: page, atCharacterIndex: 2))

        NotificationCenter.default.post(
            name: .PDFDocumentDidFindMatch,
            object: doc,
            userInfo: [PDFDocumentFoundSelectionKey: fakeSelection]
        )

        XCTAssertTrue(receivedMatches.isEmpty, "Late match notification after cancellation must be dropped.")
        XCTAssertFalse(completeCalled, "Cancelled search must not receive onComplete.")
    }

    func testMultiPaneLeaseLifecycleTransitions() throws {
        let url = try makeTemporaryPDF(pageCount: 2, named: "multi-lease") { _ in "Content" }
        let resource = PDFResourceSession(access: SecurityScopeSpy())
        XCTAssertTrue(resource.open(url: url))
        XCTAssertNotNil(resource.documentSession)

        let pane1 = PDFPaneModel(id: PaneID(), resourceSession: resource)
        let pane2 = PDFPaneModel(id: PaneID(), resourceSession: resource)
        let pane3 = PDFPaneModel(id: PaneID(), resourceSession: resource)
        XCTAssertEqual(resource.activeLeaseCount, 3)

        pane1.close()
        XCTAssertEqual(resource.activeLeaseCount, 2)
        XCTAssertNotNil(resource.documentSession, "Resource must remain active while 2 panes remain.")

        pane2.close()
        XCTAssertEqual(resource.activeLeaseCount, 1)
        XCTAssertNotNil(resource.documentSession, "Resource must remain active while 1 pane remains.")

        let pane4 = PDFPaneModel(id: PaneID(), resourceSession: resource)
        XCTAssertEqual(resource.activeLeaseCount, 2)
        XCTAssertNotNil(resource.documentSession)

        pane3.close()
        XCTAssertEqual(resource.activeLeaseCount, 1)
        XCTAssertNotNil(resource.documentSession)

        pane4.close()
        XCTAssertEqual(resource.activeLeaseCount, 0)
        XCTAssertNil(resource.documentSession, "Resource must close when last pane is closed.")
    }

    func testResourceCloseInvalidatesSearchCoordinator() throws {
        let url = try makeTemporaryPDF(pageCount: 10, named: "close-search") { _ in "Searchable text" }
        let resource = PDFResourceSession(access: SecurityScopeSpy())
        XCTAssertTrue(resource.open(url: url))

        let paneID = UUID()
        resource.searchCoordinator.requestSearch(
            paneID: paneID,
            query: "Searchable",
            onComplete: { _ in }
        )
        XCTAssertTrue(resource.searchCoordinator.isFinding)

        resource.close()
        XCTAssertFalse(resource.searchCoordinator.isFinding, "Closing resource must cancel all search coordinator operations.")
        XCTAssertEqual(resource.searchCoordinator.queuedCount, 0)
    }

    // MARK: - 12: Failed Open & Save Safety Guarantees

    func testFailedOpenPreservesExistingDocumentAndLease() throws {
        let validURL = try makeTemporaryPDF(pageCount: 2, named: "valid-doc") { _ in "Valid" }
        let invalidURL = URL(fileURLWithPath: "/nonexistent/path/fake.pdf")

        let resource = PDFResourceSession(access: SecurityScopeSpy())
        XCTAssertTrue(resource.open(url: validURL))
        let originalDoc = try XCTUnwrap(resource.document)

        XCTAssertFalse(resource.open(url: invalidURL))
        XCTAssertTrue(resource.document === originalDoc, "Failed open must keep existing document instance.")
        XCTAssertEqual(resource.fileURL, validURL)
        XCTAssertNotNil(resource.documentSession)
    }

    func testFailedSavePreservesUnsavedChangesAndAnnotations() throws {
        let url = try makeTemporaryPDF(pageCount: 1, named: "conflict-doc") { _ in "Original content" }
        let resource = PDFResourceSession(access: SecurityScopeSpy())
        XCTAssertTrue(resource.open(url: url))
        let doc = try XCTUnwrap(resource.document)
        let page = try XCTUnwrap(doc.page(at: 0))

        let pane = PDFPaneModel(id: PaneID(), resourceSession: resource)
        let sel = try XCTUnwrap(doc.selection(from: page, atCharacterIndex: 0, to: page, atCharacterIndex: 5))
        pane.updateSelection(sel)
        XCTAssertNotNil(pane.addHighlightToSelection())
        XCTAssertTrue(resource.hasUnsavedChanges)

        // Simulate external modification to force conflict
        try "External overwrite".data(using: .utf8)?.write(to: url)

        let outcome = resource.save()
        guard case .conflict = outcome else {
            XCTFail("Expected conflict save outcome, got \(outcome)")
            return
        }

        XCTAssertTrue(resource.hasUnsavedChanges, "Unsaved changes must not be cleared on conflict.")
        XCTAssertEqual(page.annotations.count, 1, "In-memory annotations must remain intact.")
    }

    // MARK: - Note Anchor Stability

    func testNoteAnchorPresentationRecalculationViaResolver() throws {
        let logicalBounds = CGRect(x: 100, y: 200, width: 32, height: 32)
        let doc = PDFDocument()
        let draft = NoteDraft(
            pageIndex: 0,
            bounds: logicalBounds,
            excerpt: "Sample excerpt",
            isPageLevel: false,
            document: doc
        )
        let store = NoteComposerStore()
        let initialPresentation = CGRect(x: 120, y: 250, width: 32, height: 32)
        XCTAssertTrue(store.begin(
            mode: .create(draft),
            anchorRect: initialPresentation,
            pageLabel: "1",
            excerpt: "Sample excerpt",
            contents: "Draft note text",
            style: .newNote
        ))

        let session = try XCTUnwrap(store.session)
        XCTAssertEqual(session.logicalPageIndex, 0)
        XCTAssertEqual(session.logicalBounds, logicalBounds)
        XCTAssertEqual(session.anchorRect, initialPresentation)

        // Simulate resize / reparenting via PageAnchorResolving mock
        final class MockAnchorResolver: PageAnchorResolving {
            var nextRect: CGRect?
            func containerRect(forPageBounds bounds: CGRect, pageIndex: Int) -> CGRect? {
                nextRect
            }
        }

        let resolver = MockAnchorResolver()
        let updatedPresentation = CGRect(x: 160, y: 310, width: 40, height: 40)
        resolver.nextRect = updatedPresentation

        XCTAssertTrue(store.updatePresentationAnchor(using: resolver))
        XCTAssertEqual(session.anchorRect, updatedPresentation, "Presentation anchor rect updated.")
        XCTAssertEqual(session.logicalBounds, logicalBounds, "Authoritative page-space bounds remained untouched.")
        XCTAssertEqual(session.logicalPageIndex, 0, "Authoritative page index remained untouched.")
    }

    // MARK: - Review Items: Convert, Lifecycle Sync, Lease & Commit

    func testConvertMarkupSelectionUpdatesToReplacementAnnotationAndAllowsSubsequentEdits() throws {
        let url = try makeTemporaryPDF(pageCount: 1, named: "convert-select") { _ in
            "Text to highlight, convert and edit"
        }
        let resource = PDFResourceSession(access: SecurityScopeSpy())
        XCTAssertTrue(resource.open(url: url))
        let doc = try XCTUnwrap(resource.document)
        let page = try XCTUnwrap(doc.page(at: 0))

        let pane = PDFPaneModel(id: PaneID(), resourceSession: resource)
        let sel = try XCTUnwrap(doc.selection(from: page, atCharacterIndex: 0, to: page, atCharacterIndex: 4))
        pane.updateSelection(sel)
        XCTAssertNotNil(pane.addHighlightToSelection())

        // Select the new highlight
        let annotation = try XCTUnwrap(page.annotations.first)
        let hitPoint = CGPoint(x: annotation.bounds.midX, y: annotation.bounds.midY)
        XCTAssertTrue(pane.selectMarkup(at: hitPoint, on: page))
        XCTAssertTrue(pane.canModifySelectedMarkup)
        let originalAnnotation = annotation

        // Convert markup: Highlight -> Underline
        XCTAssertTrue(pane.convertSelectedMarkup())
        XCTAssertTrue(pane.canModifySelectedMarkup, "Converted markup must remain modifiable.")

        let replacementSelection = try XCTUnwrap(pane.selectedMarkup)
        XCTAssertTrue(replacementSelection.annotation !== originalAnnotation, "Selected markup must reference the new replacement annotation.")
        XCTAssertEqual(replacementSelection.kind, .underline)
        XCTAssertTrue(page.annotations.contains(where: { $0 === replacementSelection.annotation }))

        // Subsequent recolour must succeed on the replacement annotation
        XCTAssertTrue(pane.recolorSelectedMarkup(to: .systemRed))
        XCTAssertEqual(replacementSelection.annotation.color.usingColorSpace(.sRGB)?.redComponent ?? 0, 1.0, accuracy: 0.05)

        // Subsequent delete must remove the replacement annotation
        XCTAssertTrue(pane.deleteSelectedMarkup())
        XCTAssertEqual(page.annotations.count, 0)
        XCTAssertNil(pane.selectedMarkup)
    }

    func testDocumentReplacementSynchronizesAllObservingPanes() throws {
        let url1 = try makeTemporaryPDF(pageCount: 5, named: "doc-sync-1") { page in "Page \(page)" }
        let url2 = try makeTemporaryPDF(pageCount: 2, named: "doc-sync-2") { page in "Short Page \(page)" }

        let resource = PDFResourceSession(access: SecurityScopeSpy())
        XCTAssertTrue(resource.open(url: url1))
        let doc1 = try XCTUnwrap(resource.document)
        let page1_0 = try XCTUnwrap(doc1.page(at: 0))

        let paneA = PDFPaneModel(id: PaneID(), resourceSession: resource)
        let paneB = PDFPaneModel(id: PaneID(), resourceSession: resource)

        paneA.goToPage(4)
        paneB.goToPage(3)
        XCTAssertEqual(paneA.currentPageIndex, 4)
        XCTAssertEqual(paneB.currentPageIndex, 3)

        // Setup selections and search in Pane A
        let sel = try XCTUnwrap(doc1.selection(from: page1_0, atCharacterIndex: 0, to: page1_0, atCharacterIndex: 3))
        paneA.updateSelection(sel)
        paneA.search("Page")
        XCTAssertNotNil(paneA.currentSelection)

        // Setup an uncommitted note draft in Pane B
        let draft = NoteDraft(pageIndex: 0, bounds: CGRect(x: 10, y: 10, width: 30, height: 30), excerpt: "Ex", isPageLevel: false, document: doc1)
        XCTAssertTrue(paneB.noteComposerStore.begin(mode: .create(draft), anchorRect: .zero, pageLabel: "1", excerpt: "Ex", contents: "", style: .newNote))
        paneB.noteComposerStore.session?.contents = "Unsaved draft text"
        XCTAssertTrue(paneB.noteComposerStore.hasUncommittedChanges)

        // Replace document with doc2 (2 pages)
        XCTAssertTrue(resource.open(url: url2))
        let doc2 = try XCTUnwrap(resource.document)
        XCTAssertEqual(doc2.pageCount, 2)

        // Verify Pane A was synchronized:
        XCTAssertLessThanOrEqual(paneA.currentPageIndex, 1, "Page index must be clamped to new document's page count.")
        XCTAssertNil(paneA.currentSelection, "Stale selection must be cleared.")
        XCTAssertNil(paneA.selectedMarkup, "Stale markup selection must be cleared.")
        XCTAssertTrue(paneA.searchSession.document === doc2, "Search session must be rebound to new document.")

        // Verify Pane B was synchronized:
        XCTAssertLessThanOrEqual(paneB.currentPageIndex, 1, "Page index must be clamped.")
        XCTAssertTrue(paneB.noteComposerStore.hasSession, "Uncommitted note draft must be preserved.")
        XCTAssertEqual(paneB.noteComposerStore.session?.status(in: paneB), .documentReplaced, "Draft status reflects document replacement.")
    }

    func testClosingModelDoesNotReleaseResourceSessionWhileOtherPanesAlive() throws {
        let url = try makeTemporaryPDF(pageCount: 2, named: "lease-compat") { _ in "Content" }
        let resource = PDFResourceSession(access: SecurityScopeSpy())
        XCTAssertTrue(resource.open(url: url))

        let paneA = PDFPaneModel(id: PaneID(), resourceSession: resource)
        let modelA = PDFDocumentModel(resourceSession: resource, paneModel: paneA)
        let paneB = PDFPaneModel(id: PaneID(), resourceSession: resource)

        XCTAssertEqual(resource.activeLeaseCount, 2)
        XCTAssertNotNil(resource.documentSession)

        // Close modelA: should release Pane A's lease only
        modelA.close()
        XCTAssertEqual(resource.activeLeaseCount, 1, "Pane B lease must still be active.")
        XCTAssertNotNil(resource.documentSession, "DocumentSession must remain open.")
        XCTAssertTrue(resource.isLoaded)
        XCTAssertNotNil(paneB.document)

        // Close Pane B: last lease released -> resource cleans up
        paneB.close()
        XCTAssertEqual(resource.activeLeaseCount, 0)
        XCTAssertNil(resource.documentSession, "Resource must close when all leases are released.")
    }

    func testAnchorRectObservableObjectNotificationAndIDs() throws {
        let logicalBounds = CGRect(x: 50, y: 60, width: 32, height: 32)
        let doc = PDFDocument()
        let draft = NoteDraft(pageIndex: 0, bounds: logicalBounds, excerpt: "Test", isPageLevel: false, document: doc)
        let session = NoteComposerSession(mode: .create(draft), anchorRect: CGRect(x: 10, y: 20, width: 32, height: 32), pageLabel: "1", excerpt: "Test", contents: "Draft", style: .newNote)

        XCTAssertNil(session.targetAnnotationID, "Creation mode has no targetAnnotationID.")
        XCTAssertNil(session.targetAnnotationUUID, "Creation mode has no targetAnnotationUUID.")

        var changeCount = 0
        let cancellable = session.objectWillChange.sink { _ in
            changeCount += 1
        }
        defer { cancellable.cancel() }

        let newRect = CGRect(x: 100, y: 200, width: 32, height: 32)
        session.updatePresentationAnchorRect(newRect)
        XCTAssertEqual(session.anchorRect, newRect)
        XCTAssertEqual(changeCount, 1, "Updating anchorRect must emit ObservableObject objectWillChange notification.")
    }

    func testNoteComposerCommitClearsPaneSelections() throws {
        let url = try makeTemporaryPDF(pageCount: 1, named: "note-commit-clear") { _ in "Selectable text content" }
        let resource = PDFResourceSession(access: SecurityScopeSpy())
        XCTAssertTrue(resource.open(url: url))
        let doc = try XCTUnwrap(resource.document)
        let page = try XCTUnwrap(doc.page(at: 0))

        let pane = PDFPaneModel(id: PaneID(), resourceSession: resource)
        let sel = try XCTUnwrap(doc.selection(from: page, atCharacterIndex: 0, to: page, atCharacterIndex: 4))
        pane.updateSelection(sel)
        XCTAssertNotNil(pane.currentSelection)

        let draft = try XCTUnwrap(pane.selectionNoteDraft())
        XCTAssertTrue(pane.noteComposerStore.begin(mode: .create(draft), anchorRect: .zero, pageLabel: "1", excerpt: "Sele", contents: "Saved note", style: .newNote))

        // Commit note via pane
        let result = pane.noteComposerStore.commit(using: pane)
        guard case .success = result else {
            XCTFail("Expected successful commit, got \(result)")
            return
        }

        XCTAssertNil(pane.currentSelection, "Committing note must clear pane's text selection.")
        XCTAssertNil(pane.selectedMarkup, "Committing note must clear pane's markup selection.")
    }

    func testPaneSessionConstructorConsistencyConstraints() {
        let resourceA = PDFResourceSession(access: SecurityScopeSpy())
        let paneA = PDFPaneModel(id: PaneID(), resourceSession: resourceA)

        // Valid direct constructor
        let session1 = PDFPaneSession(paneID: paneA.id, paneModel: paneA, resourceSession: resourceA)
        XCTAssertTrue(session1.paneModel === paneA)
        XCTAssertTrue(session1.resourceSession === resourceA)

        // Valid convenience constructor
        let session2 = PDFPaneSession(paneModel: paneA)
        XCTAssertTrue(session2.paneModel === paneA)
        XCTAssertTrue(session2.resourceSession === resourceA)
    }

    // MARK: - Helpers

    private func makeTemporaryPDF(
        pageCount: Int,
        named name: String,
        text: @escaping (Int) -> String
    ) throws -> URL {
        let url = try PDFFixtureFactory.writeTemporaryPDF(pageCount: pageCount, named: name, text: text)
        temporaryFiles.append(url)
        return url
    }

    private func makeDocument(
        pageCount: Int,
        text: @escaping (Int) -> String
    ) throws -> PDFDocument {
        let data = try PDFFixtureFactory.makePDFData(pageCount: pageCount, text: text)
        return try XCTUnwrap(PDFDocument(data: data))
    }
}
