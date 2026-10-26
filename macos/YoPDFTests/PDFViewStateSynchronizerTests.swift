import AppKit
import PDFKit
import XCTest
@testable import YoPDFCore

@MainActor
final class PDFViewStateSynchronizerTests: XCTestCase {
    private func makeDocument(pageCount: Int = 5) throws -> PDFDocument {
        try XCTUnwrap(PDFDocument(data: PDFFixtureFactory.makePDFData(pageCount: pageCount)))
    }

    private func makeView() -> PDFView {
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        return view
    }

    private func update(
        _ synchronizer: PDFViewStateSynchronizer,
        _ view: PDFView,
        _ document: PDFDocument?,
        pageIndex: Int = 2,
        pageRevision: Int = 0,
        autoScales: Bool = false,
        scale: CGFloat = 1.5,
        zoomRevision: Int = 0
    ) {
        synchronizer.update(
            pdfView: view,
            document: document,
            currentPageIndex: pageIndex,
            pageNavigationRevision: pageRevision,
            autoScales: autoScales,
            zoomScale: scale,
            zoomCommandRevision: zoomRevision
        )
    }

    func testReplacementRestoresPageAndPointWithoutPublishingTransientState() throws {
        let document = try makeDocument()
        let view = makeView()
        let synchronizer = PDFViewStateSynchronizer()
        update(synchronizer, view, document)
        let page = try XCTUnwrap(document.page(at: 2))
        view.go(to: PDFDestination(page: page, at: CGPoint(x: 70, y: 530)))
        let before = try XCTUnwrap(view.currentDestination)
        let observer = FeedbackObserver(view: view, synchronizer: synchronizer)
        defer { observer.detach() }
        observer.pageIndex = 2
        observer.scale = 1.5

        let replacement = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(document.dataRepresentation())))
        update(synchronizer, view, replacement)

        XCTAssertTrue(view.currentPage === replacement.page(at: 2))
        let after = try XCTUnwrap(view.currentDestination)
        XCTAssertEqual(after.point.x, before.point.x, accuracy: 1)
        XCTAssertEqual(after.point.y, before.point.y, accuracy: 1)
        XCTAssertEqual(view.scaleFactor, 1.5, accuracy: 0.001)
        XCTAssertEqual(observer.pageIndex, 2)
        XCTAssertEqual(observer.scale, 1.5, accuracy: 0.001)
        XCTAssertGreaterThan(observer.ignoredNotifications, 0,
                             "PDFKit's reset notifications must be suppressed during replacement")
        XCTAssertFalse(synchronizer.isApplyingUpdate)
    }

    func testFitReplacementRestoresPageAndPoint() throws {
        let document = try makeDocument()
        let view = makeView()
        let synchronizer = PDFViewStateSynchronizer()
        update(synchronizer, view, document, autoScales: true)
        view.go(to: PDFDestination(page: try XCTUnwrap(document.page(at: 2)),
                                   at: CGPoint(x: 0, y: 530)))
        let before = try XCTUnwrap(view.currentDestination)
        let replacement = try makeDocument()
        update(synchronizer, view, replacement, autoScales: true)

        XCTAssertTrue(view.autoScales)
        XCTAssertTrue(view.currentPage === replacement.page(at: 2))
        XCTAssertEqual(try XCTUnwrap(view.currentDestination).point.y, before.point.y, accuracy: 1)
    }

    func testRefreshDuringNativeZoomDoesNotReplayStalePageOrScale() throws {
        let document = try makeDocument()
        let view = makeView()
        let synchronizer = PDFViewStateSynchronizer()
        update(synchronizer, view, document, autoScales: true)

        // Native pinch/reflow can move the visible page before SwiftUI receives
        // its page notification. An unrelated refresh still has the old values.
        view.autoScales = false
        view.scaleFactor = 2
        view.go(to: PDFDestination(page: try XCTUnwrap(document.page(at: 3)),
                                   at: CGPoint(x: 70, y: 500)))
        let before = try XCTUnwrap(view.currentDestination)
        update(synchronizer, view, document, autoScales: true)

        XCTAssertFalse(view.autoScales)
        XCTAssertEqual(view.scaleFactor, 2, accuracy: 0.001)
        XCTAssertTrue(view.currentPage === document.page(at: 3))
        XCTAssertEqual(try XCTUnwrap(view.currentDestination).point.y, before.point.y, accuracy: 1)

        // Mirroring the resulting page also must not jump to the page top.
        update(synchronizer, view, document, pageIndex: 3, scale: 2)
        XCTAssertEqual(try XCTUnwrap(view.currentDestination).point.y, before.point.y, accuracy: 1)
    }

    func testPageCommandOverridesNativeNavigationAndDoesNotResetZoom() throws {
        let document = try makeDocument()
        let view = makeView()
        let synchronizer = PDFViewStateSynchronizer()
        update(synchronizer, view, document)
        view.scaleFactor = 2
        view.go(to: try XCTUnwrap(document.page(at: 3)))
        update(synchronizer, view, document, pageIndex: 1, pageRevision: 1)
        XCTAssertTrue(view.currentPage === document.page(at: 1))
        XCTAssertEqual(view.scaleFactor, 2, accuracy: 0.001)
    }

    func testReplacementWithPendingPageCommandUsesCommandInsteadOfOldViewport() throws {
        let document = try makeDocument()
        let view = makeView()
        let synchronizer = PDFViewStateSynchronizer()
        update(synchronizer, view, document)
        let replacement = try makeDocument()
        update(synchronizer, view, replacement, pageIndex: 4, pageRevision: 1)
        XCTAssertTrue(view.currentPage === replacement.page(at: 4))
    }

    func testReplacementWithFewerPagesClampsTargetAndClearingDocumentIsSafe() throws {
        let view = makeView()
        let synchronizer = PDFViewStateSynchronizer()
        update(synchronizer, view, try makeDocument(), pageIndex: 4)
        let shorter = try makeDocument(pageCount: 2)
        update(synchronizer, view, shorter, pageIndex: 4)
        XCTAssertTrue(view.currentPage === shorter.page(at: 1))
        update(synchronizer, view, nil)
        XCTAssertNil(view.document)
        XCTAssertFalse(synchronizer.isApplyingUpdate)
    }

    func testReplacementRestoresLiveViewportWhenPageFeedbackIsPending() throws {
        let document = try makeDocument()
        let view = makeView()
        let synchronizer = PDFViewStateSynchronizer()
        update(synchronizer, view, document)
        view.go(to: PDFDestination(page: try XCTUnwrap(document.page(at: 3)),
                                   at: CGPoint(x: 70, y: 500)))
        let before = try XCTUnwrap(view.currentDestination)
        let replacement = try makeDocument()
        // Page feedback is still queued, so the model still reports page 2.
        update(synchronizer, view, replacement)
        XCTAssertTrue(view.currentPage === replacement.page(at: 3))
        XCTAssertEqual(try XCTUnwrap(view.currentDestination).point.y, before.point.y, accuracy: 1)
    }

    func testQueuedViewReportCannotOverwriteNewerCommandsOrDocument() throws {
        let url = try PDFFixtureFactory.writeTemporaryPDF()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = PDFDocumentModel(access: SecurityScopeSpy())
        XCTAssertTrue(model.open(url: url))
        let document = try XCTUnwrap(model.document)
        let pageRevision = model.pageNavigationRevision
        let zoomRevision = model.zoomCommandRevision
        model.goToPage(2)
        model.updateViewState(document: document, pageIndex: 0, scale: 1,
                              pageNavigationRevision: pageRevision, zoomCommandRevision: zoomRevision)
        XCTAssertEqual(model.currentPageIndex, 2)
        model.setZoomScale(2)
        model.updateViewState(document: document, pageIndex: 0, scale: 1,
                              pageNavigationRevision: model.pageNavigationRevision,
                              zoomCommandRevision: zoomRevision)
        XCTAssertEqual(model.zoomScale, 2)
        model.updateViewState(document: try makeDocument(), pageIndex: 0, scale: 1,
                              pageNavigationRevision: model.pageNavigationRevision,
                              zoomCommandRevision: model.zoomCommandRevision)
        XCTAssertEqual(model.currentPageIndex, 2)
        XCTAssertEqual(model.zoomScale, 2)
        model.updateViewState(document: document, pageIndex: 1, scale: 1.75,
                              pageNavigationRevision: model.pageNavigationRevision,
                              zoomCommandRevision: model.zoomCommandRevision)
        XCTAssertEqual(model.currentPageIndex, 1)
        XCTAssertEqual(model.zoomScale, 1.75)
    }

    func testSteppingPastLastPageKeepsInPageScrollOffset() throws {
        let url = try PDFFixtureFactory.writeTemporaryPDF()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = PDFDocumentModel(access: SecurityScopeSpy())
        XCTAssertTrue(model.open(url: url))
        let document = try XCTUnwrap(model.document)
        let view = makeView()
        let synchronizer = PDFViewStateSynchronizer()
        update(synchronizer, view, document, autoScales: true)

        let lastIndex = model.pageCount - 1
        model.goToPage(lastIndex)
        update(synchronizer, view, document,
               pageIndex: lastIndex,
               pageRevision: model.pageNavigationRevision,
               autoScales: true)
        let lastPage = try XCTUnwrap(document.page(at: lastIndex))
        view.go(to: PDFDestination(page: lastPage, at: CGPoint(x: 0, y: 520)))
        let before = try XCTUnwrap(view.currentDestination)
        let revision = model.pageNavigationRevision

        // The thumbnail sidebar arrow key path when already on the last page.
        model.goToNextPage()
        XCTAssertEqual(model.pageNavigationRevision, revision)
        update(synchronizer, view, document,
               pageIndex: model.currentPageIndex,
               pageRevision: model.pageNavigationRevision,
               autoScales: true)

        XCTAssertTrue(view.currentPage === lastPage)
        XCTAssertEqual(try XCTUnwrap(view.currentDestination).point.y, before.point.y, accuracy: 1,
                       "a no-op page step must not reset the in-page scroll offset")
    }

    func testMirroringNativePageDoesNotIssueNavigationCommand() throws {
        let url = try PDFFixtureFactory.writeTemporaryPDF()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = PDFDocumentModel(access: SecurityScopeSpy())
        XCTAssertTrue(model.open(url: url))
        let revision = model.pageNavigationRevision
        model.updateCurrentPageIndex(1)
        XCTAssertEqual(model.currentPageIndex, 1)
        XCTAssertEqual(model.pageNavigationRevision, revision)
        model.goToPage(1)
        XCTAssertEqual(model.pageNavigationRevision, revision + 1,
                       "an explicit command must work even when the model already reports that page")
        model.updateCurrentPageIndex(NSNotFound)
        XCTAssertEqual(model.currentPageIndex, 1)
    }
}

@MainActor
private final class FeedbackObserver: NSObject {
    let view: PDFView
    let synchronizer: PDFViewStateSynchronizer
    var pageIndex = 0
    var scale: CGFloat = 1
    var ignoredNotifications = 0

    init(view: PDFView, synchronizer: PDFViewStateSynchronizer) {
        self.view = view
        self.synchronizer = synchronizer
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(changed(_:)), name: .PDFViewPageChanged, object: view)
        center.addObserver(self, selector: #selector(changed(_:)), name: .PDFViewScaleChanged, object: view)
    }

    func detach() { NotificationCenter.default.removeObserver(self) }

    @objc private func changed(_ notification: Notification) {
        guard !synchronizer.isApplyingUpdate else {
            ignoredNotifications += 1
            return
        }
        if notification.name == .PDFViewPageChanged,
           let document = view.document, let page = view.currentPage {
            pageIndex = document.index(for: page)
        } else if notification.name == .PDFViewScaleChanged {
            scale = view.scaleFactor
        }
    }
}
