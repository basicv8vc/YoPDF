import Foundation
import XCTest
@testable import YoPDFCore

@MainActor
final class RecentDocumentsStoreTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var temporaryFiles: [URL] = []

    override func setUp() {
        super.setUp()
        suiteName = "YoPDFRecentDocumentsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        temporaryFiles.removeAll()
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testBookmarksAndReadingPositionSurviveStoreRecreation() throws {
        let url = try makePDF(named: "persisted")
        let firstStore = RecentDocumentsStore(defaults: defaults)
        XCTAssertTrue(firstStore.recordOpened(url))

        let position = RecentReadingPosition(
            pageIndex: 2,
            zoomScale: 1.5,
            usesAutomaticScaling: false
        )
        firstStore.updateReadingPosition(position, for: url)

        let restartedStore = RecentDocumentsStore(defaults: defaults)
        let item = try XCTUnwrap(restartedStore.items.first)
        let resolvedURL = try restartedStore.resolveURL(for: item)

        XCTAssertEqual(resolvedURL.standardizedFileURL, url.standardizedFileURL)
        XCTAssertEqual(restartedStore.readingPosition(for: resolvedURL), position)
        XCTAssertEqual(item.displayName, "persisted.pdf")
    }

    func testRecordingAnOpenFileMovesItToFrontAndKeepsItsPosition() throws {
        let firstURL = try makePDF(named: "first")
        let secondURL = try makePDF(named: "second")
        let store = RecentDocumentsStore(defaults: defaults)

        XCTAssertTrue(store.recordOpened(firstURL))
        let firstID = try XCTUnwrap(store.items.first?.id)
        let position = RecentReadingPosition(pageIndex: 1, zoomScale: 2, usesAutomaticScaling: false)
        store.updateReadingPosition(position, for: firstURL)
        XCTAssertTrue(store.recordOpened(secondURL))
        XCTAssertTrue(store.recordOpened(firstURL))

        XCTAssertEqual(store.items.map(\.displayName), ["first.pdf", "second.pdf"])
        XCTAssertEqual(store.items.first?.id, firstID)
        XCTAssertEqual(store.items.first?.readingPosition, position)
    }

    func testListKeepsOnlyTheTenMostRecentlyOpenedFiles() throws {
        let directory = try TemporaryDirectory("recent-documents")
        defer { directory.remove() }
        let store = RecentDocumentsStore(defaults: defaults)
        let pdfData = try PDFFixtureFactory.makePDFData(pageCount: 1)

        for index in 0..<(RecentDocumentsStore.maximumCount + 2) {
            let url = try directory.write("recent-\(index).pdf", pdfData)
            XCTAssertTrue(store.recordOpened(url))
        }

        XCTAssertEqual(store.items.count, RecentDocumentsStore.maximumCount)
        XCTAssertEqual(store.items.first?.displayName, "recent-11.pdf")
        XCTAssertEqual(store.items.last?.displayName, "recent-2.pdf")
    }

    func testBookmarkResolvesAfterThePDFIsMoved() throws {
        let originalURL = try makePDF(named: "before-move")
        let store = RecentDocumentsStore(defaults: defaults)
        XCTAssertTrue(store.recordOpened(originalURL))
        let item = try XCTUnwrap(store.items.first)
        let movedURL = originalURL.deletingLastPathComponent().appendingPathComponent("after-move.pdf")
        try FileManager.default.moveItem(at: originalURL, to: movedURL)

        let restartedStore = RecentDocumentsStore(defaults: defaults)
        let resolvedURL = try restartedStore.resolveURL(for: item)
        XCTAssertEqual(resolvedURL.standardizedFileURL, movedURL.standardizedFileURL)
    }

    func testRelinkAfterBrokenBookmarkUpdatesOriginalEntryAndRemovesDuplicate() throws {
        let originalURL = try makePDF(named: "relink-original")
        let targetDirectory = try TemporaryDirectory("recent-relink-target")
        defer { targetDirectory.remove() }
        let targetURL = try targetDirectory.write(
            "relinked.pdf",
            PDFFixtureFactory.makePDFData(pageCount: 4)
        )
        let store = RecentDocumentsStore(
            defaults: defaults,
            bookmarkDataProvider: { url in
                if url.standardizedFileURL == originalURL.standardizedFileURL {
                    return Data([0x01, 0x02, 0x03])
                }
                return try url.bookmarkData(options: [.withSecurityScope])
            }
        )
        XCTAssertTrue(store.recordOpened(originalURL))
        let originalID = try XCTUnwrap(store.items.first?.id)
        let position = RecentReadingPosition(pageIndex: 2, zoomScale: 1.6, usesAutomaticScaling: false)
        store.updateReadingPosition(position, for: originalURL)
        let originalItem = try XCTUnwrap(store.items.first { $0.id == originalID })

        XCTAssertThrowsError(try store.resolveURL(for: originalItem))

        // Simulate the same PDF having appeared under its new path before the
        // user relinks the older, now-unresolvable entry.
        XCTAssertTrue(store.recordOpened(targetURL))
        let duplicateID = try XCTUnwrap(store.items.first { $0.lastKnownPath == targetURL.path }?.id)
        let model = PDFDocumentModel(recentDocuments: store)

        XCTAssertTrue(model.open(url: targetURL, relinking: originalItem))

        XCTAssertEqual(model.currentPageIndex, position.pageIndex)
        XCTAssertEqual(model.zoomScale, CGFloat(position.zoomScale), accuracy: 0.0001)
        XCTAssertEqual(store.items.count, 1)
        let relinked = try XCTUnwrap(store.items.first)
        XCTAssertEqual(relinked.id, originalID)
        XCTAssertNotEqual(relinked.id, duplicateID)
        XCTAssertEqual(relinked.lastKnownPath, targetURL.standardizedFileURL.path)
        XCTAssertEqual(relinked.displayName, targetURL.lastPathComponent)
        XCTAssertNotEqual(relinked.bookmarkData, originalItem.bookmarkData)
        XCTAssertEqual(relinked.readingPosition, position)
        let relaunchedStore = RecentDocumentsStore(defaults: defaults)
        XCTAssertEqual(relaunchedStore.items.count, 1)
        let relaunchedItem = try XCTUnwrap(relaunchedStore.items.first)
        XCTAssertEqual(relaunchedItem.id, originalID)
        XCTAssertEqual(relaunchedItem.readingPosition, position)
        XCTAssertEqual(
            try relaunchedStore.resolveURL(for: relaunchedItem).standardizedFileURL,
            targetURL.standardizedFileURL
        )
        model.close()
    }

    func testFailedRelinkOpenLeavesOriginalEntryUnchanged() throws {
        let originalURL = try makePDF(named: "relink-failure-original")
        let targetDirectory = try TemporaryDirectory("recent-relink-failure")
        defer { targetDirectory.remove() }
        let brokenURL = try targetDirectory.write("broken.pdf", Data("not a PDF".utf8))
        let store = RecentDocumentsStore(
            defaults: defaults,
            bookmarkDataProvider: { url in
                if url.standardizedFileURL == originalURL.standardizedFileURL {
                    return Data([0x01, 0x02, 0x03])
                }
                return try url.bookmarkData(options: [.withSecurityScope])
            }
        )
        XCTAssertTrue(store.recordOpened(originalURL))
        let position = RecentReadingPosition(pageIndex: 1, zoomScale: 1.4, usesAutomaticScaling: false)
        store.updateReadingPosition(position, for: originalURL)
        let originalItem = try XCTUnwrap(store.items.first)
        let originalEntries = store.items
        let model = PDFDocumentModel(recentDocuments: store)

        XCTAssertFalse(model.open(url: brokenURL, relinking: originalItem))

        XCTAssertEqual(model.lastError, .unreadable)
        XCTAssertEqual(store.items, originalEntries)
        XCTAssertEqual(store.items.first?.readingPosition, position)
        model.close()
    }

    func testCancelledRelinkSelectionLeavesOriginalEntryUnchanged() throws {
        let originalURL = try makePDF(named: "relink-cancel")
        let store = RecentDocumentsStore(
            defaults: defaults,
            bookmarkDataProvider: { _ in Data([0x01, 0x02, 0x03]) }
        )
        XCTAssertTrue(store.recordOpened(originalURL))
        let originalItem = try XCTUnwrap(store.items.first)
        let originalEntries = store.items

        XCTAssertFalse(try store.relink(originalItem, to: nil))

        XCTAssertEqual(store.items, originalEntries)
    }

    func testModelRestoresPageAndManualZoomAndClampsPageAfterDocumentChanges() throws {
        let url = try makePDF(pageCount: 4, named: "position")
        let store = RecentDocumentsStore(defaults: defaults)
        let firstModel = PDFDocumentModel(recentDocuments: store)

        XCTAssertTrue(firstModel.open(url: url))
        firstModel.goToPage(3)
        firstModel.setZoomScale(1.75)
        firstModel.close()

        let reopenedModel = PDFDocumentModel(recentDocuments: RecentDocumentsStore(defaults: defaults))
        XCTAssertTrue(reopenedModel.open(url: url))
        XCTAssertEqual(reopenedModel.currentPageIndex, 3)
        XCTAssertFalse(reopenedModel.isAutoScaling)
        XCTAssertEqual(reopenedModel.zoomScale, 1.75, accuracy: 0.0001)
        reopenedModel.close()

        try PDFFixtureFactory.makePDFData(pageCount: 2).write(to: url, options: .atomic)
        let shortenedDocumentModel = PDFDocumentModel(recentDocuments: RecentDocumentsStore(defaults: defaults))
        XCTAssertTrue(shortenedDocumentModel.open(url: url))
        XCTAssertEqual(shortenedDocumentModel.currentPageIndex, 1)
        XCTAssertEqual(shortenedDocumentModel.zoomScale, 1.75, accuracy: 0.0001)
    }

    func testFitModeIsRestored() throws {
        let url = try makePDF(named: "fit")
        let firstModel = PDFDocumentModel(recentDocuments: RecentDocumentsStore(defaults: defaults))
        XCTAssertTrue(firstModel.open(url: url))
        firstModel.goToPage(1)
        firstModel.setZoomScale(1.5)
        firstModel.fitToWindow()
        firstModel.close()

        let reopenedModel = PDFDocumentModel(recentDocuments: RecentDocumentsStore(defaults: defaults))
        XCTAssertTrue(reopenedModel.open(url: url))
        XCTAssertEqual(reopenedModel.currentPageIndex, 1)
        XCTAssertTrue(reopenedModel.isAutoScaling)
    }

    func testUnresolvableBookmarkIsReportedWithoutDroppingEntry() throws {
        let url = try makePDF(named: "invalid-bookmark")
        let store = RecentDocumentsStore(
            defaults: defaults,
            bookmarkDataProvider: { _ in Data([0x01, 0x02, 0x03]) }
        )
        XCTAssertTrue(store.recordOpened(url))
        let item = try XCTUnwrap(store.items.first)

        XCTAssertThrowsError(try store.resolveURL(for: item)) { error in
            XCTAssertEqual(error as? RecentDocumentsError, .bookmarkCouldNotBeResolved)
        }
        XCTAssertEqual(store.items.count, 1)
    }

    func testUnreadablePreferenceValueIsNotOverwrittenByANewOpen() throws {
        let url = try makePDF(named: "preserve-corrupt-value")
        let key = "dev.yopdf.recentDocuments.v1"
        let unreadableData = Data([0xde, 0xad, 0xbe, 0xef])
        defaults.set(unreadableData, forKey: key)
        let store = RecentDocumentsStore(defaults: defaults)

        XCTAssertFalse(store.recordOpened(url))
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(defaults.data(forKey: key), unreadableData)

        store.clear()
        XCTAssertNil(defaults.data(forKey: key))

        defaults.set("future-value", forKey: key)
        let wrongTypeStore = RecentDocumentsStore(defaults: defaults)
        XCTAssertTrue(wrongTypeStore.canClear)
        XCTAssertFalse(wrongTypeStore.recordOpened(url))
        XCTAssertEqual(defaults.string(forKey: key), "future-value")
        wrongTypeStore.clear()
        XCTAssertNil(defaults.object(forKey: key))
    }

    private func makePDF(pageCount: Int = 3, named name: String) throws -> URL {
        let url = try PDFFixtureFactory.writeTemporaryPDF(pageCount: pageCount, named: name)
        temporaryFiles.append(url)
        return url
    }
}
