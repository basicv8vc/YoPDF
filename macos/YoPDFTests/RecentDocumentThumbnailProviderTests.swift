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
            isItemKnown: { _ in false }
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
    private static func writeOnePagePDF(to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw XCTUnwrapFailure()
        }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.95, alpha: 1))
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

    private struct XCTUnwrapFailure: Error {}
}
