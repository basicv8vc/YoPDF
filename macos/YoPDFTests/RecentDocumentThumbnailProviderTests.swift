import AppKit
import XCTest
@testable import YoPDFCore

/// Lifecycle tests for the recent-document preview cache: what may be written,
/// what must be cleaned up, and what happens to a render whose entry
/// disappeared while it was in flight.
@MainActor
final class RecentDocumentThumbnailProviderTests: XCTestCase {

    private var root: URL!
    private var pdfURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "YoPDFThumbnailProviderTests-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        pdfURL = root.appendingPathComponent("sample.pdf")
        try Self.writeOnePagePDF(to: pdfURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Caching behaviour

    func testKnownItemCachesItsPreviewOnDisk() async throws {
        let provider = RecentDocumentThumbnailProvider(directory: root)
        let item = Self.makeItem(id: UUID(), path: pdfURL.path)

        let image = await provider.image(for: item, url: pdfURL)
        XCTAssertNotNil(image)

        let itemDirectory = root.appendingPathComponent(
            "YoPDF/RecentThumbnails/\(item.id.uuidString)", isDirectory: true
        )
        let contents = try FileManager.default.contentsOfDirectory(atPath: itemDirectory.path)
        XCTAssertEqual(contents.count, 1)
        XCTAssertTrue(contents[0].hasSuffix(".png"))
    }

    /// A render that finishes after its entry was removed — or after the whole
    /// list was cleared — must not write its image back to the cache.
    func testUnknownItemDoesNotWriteItsRenderBack() async throws {
        let provider = RecentDocumentThumbnailProvider(
            directory: root,
            isItemCurrent: { _, _ in false }
        )
        let item = Self.makeItem(id: UUID(), path: pdfURL.path)

        let image = await provider.image(for: item, url: pdfURL)
        XCTAssertNotNil(image, "the render itself still succeeds")

        let cacheRoot = root.appendingPathComponent("YoPDF/RecentThumbnails")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: cacheRoot.path)) ?? []
        XCTAssertTrue(
            contents.isEmpty,
            "no cache directory may survive for an entry that no longer exists"
        )
    }

    /// A render that finishes after its entry was relinked to another file
    /// must not write the *old* file's preview back under the entry's id —
    /// the write-back check compares the full render identity, not just the
    /// UUID's existence.
    func testRelinkedIdentityDoesNotWriteTheOldPreviewBack() async throws {
        let item = Self.makeItem(id: UUID(), path: pdfURL.path)
        let relinkedIdentity = RecentDocumentThumbnailCachePolicy.renderIdentity(
            for: Self.makeItem(id: item.id, path: "/tmp/relinked-elsewhere.pdf")
        )
        let provider = RecentDocumentThumbnailProvider(
            directory: root,
            isItemCurrent: { _, identity in identity == relinkedIdentity }
        )

        let image = await provider.image(for: item, url: pdfURL)
        XCTAssertNotNil(image, "the render itself still succeeds")

        let cacheRoot = root.appendingPathComponent("YoPDF/RecentThumbnails")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: cacheRoot.path)) ?? []
        XCTAssertTrue(
            contents.isEmpty,
            "a superseded render must not recreate the cache entry it lost"
        )
    }

    /// Regression: relinking an entry to a different PDF that shares the old
    /// file's size and modification date must serve the *new* file's preview,
    /// not the cached image of the file the entry used to point at.
    func testRelinkToSameSizeSameDateFileGetsItsOwnPreview() async throws {
        let provider = RecentDocumentThumbnailProvider(directory: root)
        let urlA = root.appendingPathComponent("original.pdf")
        let urlB = root.appendingPathComponent("replacement.pdf")
        try Self.writeOnePagePDF(to: urlA, gray: 0.9)
        try Self.writeOnePagePDF(to: urlB, gray: 0.15)
        try Self.equalizeSizes(urlA, urlB)
        let sharedDate = Date(timeIntervalSince1970: 1_700_000_000)
        for url in [urlA, urlB] {
            try FileManager.default.setAttributes(
                [.modificationDate: sharedDate], ofItemAtPath: url.path
            )
        }
        let sizeA = try FileManager.default.attributesOfItem(atPath: urlA.path)[.size] as? Int
        let sizeB = try FileManager.default.attributesOfItem(atPath: urlB.path)[.size] as? Int
        XCTAssertEqual(sizeA, sizeB, "fixture precondition: identical file sizes")

        let id = UUID()
        let imageA = await provider.image(
            for: Self.makeItem(id: id, path: urlA.path), url: urlA
        )
        let imageB = await provider.image(
            for: Self.makeItem(id: id, path: urlB.path), url: urlB
        )

        XCTAssertNotNil(imageA)
        XCTAssertNotNil(imageB)
        XCTAssertNotEqual(
            imageA?.tiffRepresentation, imageB?.tiffRepresentation,
            "the relinked entry must show the replacement file's first page"
        )

        // The item directory keeps only the newest preview, and it must be
        // the replacement's stamp — the old stamp can never serve again.
        func fileID(_ url: URL) throws -> UInt64 {
            (try url.resourceValues(forKeys: [.fileIdentifierKey]).fileIdentifier) ?? 0
        }
        let stampA = RecentDocumentThumbnailCachePolicy.stamp(
            modificationDate: sharedDate,
            fileSize: Int64(sizeA ?? 0),
            fileIdentifier: try fileID(urlA)
        )
        let stampB = RecentDocumentThumbnailCachePolicy.stamp(
            modificationDate: sharedDate,
            fileSize: Int64(sizeB ?? 0),
            fileIdentifier: try fileID(urlB)
        )
        XCTAssertNotEqual(stampA, stampB, "distinct files must get distinct stamps")

        let itemDirectory = root.appendingPathComponent(
            "YoPDF/RecentThumbnails/\(id.uuidString)", isDirectory: true
        )
        let contents = try FileManager.default.contentsOfDirectory(atPath: itemDirectory.path)
        XCTAssertEqual(
            contents,
            [RecentDocumentThumbnailCachePolicy.fileName(stamp: stampB)],
            "the cached preview belongs to the replacement file, not the old one"
        )
    }

    // MARK: - Store change hook (no-window Clear Menu path)

    /// Clear Menu with every window closed relies on the store's change hook
    /// reaching the prune: no grid and no window observer exists then. The
    /// hook must fire with the change kind and the post-change list for every
    /// membership change.
    func testStoreChangeHookFiresForRemovalClearAndOpen() throws {
        let suiteName = "YoPDFStoreHookTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RecentDocumentsStore(
            defaults: defaults,
            bookmarkDataProvider: { _ in Data([1, 2, 3]) }
        )
        var observed: [(RecentDocumentsListChange, Int)] = []
        store.itemsDidChange = { change, items in
            observed.append((change, items.count))
        }

        XCTAssertTrue(store.recordOpened(URL(fileURLWithPath: "/tmp/hook-sample.pdf")))
        store.remove(store.items[0])
        XCTAssertTrue(store.recordOpened(URL(fileURLWithPath: "/tmp/hook-sample.pdf")))
        store.clear()

        XCTAssertEqual(observed.map(\.0), [.opened, .removed, .opened, .cleared])
        XCTAssertEqual(observed.map(\.1), [1, 0, 1, 0])
    }

    /// A relink keeps the entry's UUID, so pruning keeps its cache directory;
    /// the preview inside belongs to the file the entry no longer points at.
    /// The relink hook must drop that entry's previews outright.
    func testRelinkDropsTheOldPreviewWhileTheGridIsHidden() async throws {
        let suiteName = "YoPDFRelinkHookTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RecentDocumentsStore(
            defaults: defaults,
            bookmarkDataProvider: { _ in Data([4, 5, 6]) }
        )
        let provider = RecentDocumentThumbnailProvider(directory: root)
        // The same wiring AppDelegate installs for the whole app lifetime.
        store.itemsDidChange = { change, items in
            provider.prune(keeping: Set(items.map(\.id)))
            if case .relinked(let id) = change {
                provider.invalidate(id: id)
            }
        }

        store.recordOpened(pdfURL)
        guard let entry = store.items.first else {
            return XCTFail("the opened file must appear in the list")
        }
        _ = await provider.image(for: entry, url: pdfURL)
        let itemDirectory = root.appendingPathComponent(
            "YoPDF/RecentThumbnails/\(entry.id.uuidString)", isDirectory: true
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: itemDirectory.path),
            "precondition: the first file's preview is cached"
        )

        // Relink to a different PDF; the grid stays hidden afterwards, so no
        // render of the replacement ever runs in this scenario.
        let replacementURL = root.appendingPathComponent("replacement.pdf")
        try Self.writeOnePagePDF(to: replacementURL, gray: 0.15)
        try store.relink(entry, to: replacementURL)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: itemDirectory.path),
            "the previous file's preview must not survive the relink"
        )
        let cacheRoot = root.appendingPathComponent("YoPDF/RecentThumbnails")
        XCTAssertTrue(
            (try? FileManager.default.contentsOfDirectory(atPath: cacheRoot.path))?.isEmpty ?? false,
            "nothing else may be left behind either"
        )
    }

    /// After an invalidation the entry can be cached again: the next render
    /// writes a fresh preview, and no stale image is served meanwhile.
    func testInvalidatedEntryRendersAndCachesAgain() async throws {
        let provider = RecentDocumentThumbnailProvider(directory: root)
        let item = Self.makeItem(id: UUID(), path: pdfURL.path)

        _ = await provider.image(for: item, url: pdfURL)
        let itemDirectory = root.appendingPathComponent(
            "YoPDF/RecentThumbnails/\(item.id.uuidString)", isDirectory: true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: itemDirectory.path))

        XCTAssertTrue(provider.invalidate(id: item.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: itemDirectory.path))
        XCTAssertFalse(
            provider.invalidate(id: item.id),
            "a second invalidation has nothing left to remove"
        )

        let image = await provider.image(for: item, url: pdfURL)
        XCTAssertNotNil(image)
        XCTAssertTrue(FileManager.default.fileExists(atPath: itemDirectory.path))
    }

    // MARK: - Pruning

    func testPruneRemovesOnlyStaleEntriesAndReportsTheCount() throws {
        let provider = RecentDocumentThumbnailProvider(directory: root)
        let kept = UUID()
        let removed = UUID()
        let cacheRoot = root.appendingPathComponent("YoPDF/RecentThumbnails")
        for id in [kept, removed] {
            let directory = cacheRoot.appendingPathComponent(id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("png".utf8).write(to: directory.appendingPathComponent("1-1.png"))
        }

        let pruned = provider.prune(keeping: [kept])

        XCTAssertEqual(pruned, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: cacheRoot.appendingPathComponent(kept.uuidString).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: cacheRoot.appendingPathComponent(removed.uuidString).path
        ))
    }

    /// Clear Menu empties the list; pruning with an empty keep-set must leave
    /// no preview images on disk.
    func testPruneWithAnEmptyKeepSetClearsTheCache() throws {
        let provider = RecentDocumentThumbnailProvider(directory: root)
        let cacheRoot = root.appendingPathComponent("YoPDF/RecentThumbnails")
        for id in [UUID(), UUID()] {
            let directory = cacheRoot.appendingPathComponent(id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("png".utf8).write(to: directory.appendingPathComponent("1-1.png"))
        }

        let pruned = provider.prune(keeping: [])

        XCTAssertEqual(pruned, 2)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: cacheRoot.path)) ?? []
        XCTAssertTrue(contents.isEmpty)
    }

    // MARK: - Helpers

    private static func makeItem(id: UUID, path: String) -> RecentDocument {
        RecentDocument(
            id: id,
            displayName: (path as NSString).lastPathComponent,
            bookmarkData: Data([1]),
            lastKnownPath: path
        )
    }

    /// A minimal one-page PDF so the renderer has real content to draw.
    /// `gray` tints the page so two fixtures render visibly different images.
    private static func writeOnePagePDF(to url: URL, gray: CGFloat = 0.95) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw XCTUnwrapFailure()
        }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(mediaBox)
        context.setFillColor(CGColor(gray: 0.2, alpha: 1))
        context.fill(CGRect(x: 40, y: 320, width: 220, height: 36))
        context.setFillColor(CGColor(gray: 0.4, alpha: 1))
        for row in 0..<6 {
            context.fill(CGRect(x: 40, y: CGFloat(270 - row * 36), width: 220, height: 12))
        }
        context.endPDFPage()
        context.closePDF()
    }

    /// Pads the smaller of the two files with trailing newlines (harmless to
    /// PDF readers) so both fixtures share one file size — the precondition
    /// of the same-size relink regression test.
    private static func equalizeSizes(_ a: URL, _ b: URL) throws {
        let fileManager = FileManager.default
        let sizeA = (try fileManager.attributesOfItem(atPath: a.path)[.size] as? Int) ?? 0
        let sizeB = (try fileManager.attributesOfItem(atPath: b.path)[.size] as? Int) ?? 0
        let target = max(sizeA, sizeB)
        for (url, size) in [(a, sizeA), (b, sizeB)] where size < target {
            let padding = Data(repeating: UInt8(ascii: "\n"), count: target - size)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: padding)
        }
    }

    private struct XCTUnwrapFailure: Error {}
}
