import AppKit
import Foundation
import PDFKit
import YoPDFCore

/// Renders and caches the first page of recent PDFs for the empty-state grid.
///
/// Rendering is serialised through an actor, so showing the empty state never
/// decodes several PDFs at once. Only PNG `Data` crosses the actor boundary;
/// `NSImage` is created on the main actor where SwiftUI consumes it.
///
/// Previews contain the first page of the user's documents. They live in the
/// app's Caches directory, are excluded from backups, and are pruned when a
/// recent entry disappears. A failed render leaves the generic page outline
/// in place instead of retrying on every appearance.
@MainActor
final class RecentDocumentThumbnailProvider {

    static let shared = RecentDocumentThumbnailProvider()

    private let renderer = FirstPageRenderer()
    private let memory = NSCache<NSString, NSImage>()
    private let directory: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let cacheDirectory = base.appendingPathComponent(
            "YoPDF/RecentThumbnails", isDirectory: true
        )
        try? fileManager.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true
        )
        try? (cacheDirectory as NSURL).setResourceValue(
            true, forKey: .isExcludedFromBackupKey
        )
        directory = cacheDirectory
        memory.countLimit = 24
    }

    func image(for item: RecentDocument, url: URL?) async -> NSImage? {
        let stamp = Self.stamp(for: url, fileManager: fileManager)
        let key = "\(item.id.uuidString)/\(stamp)" as NSString
        if let cached = memory.object(forKey: key) { return cached }

        let itemDirectory = directory.appendingPathComponent(
            RecentDocumentThumbnailCachePolicy.directoryName(for: item.id),
            isDirectory: true
        )
        let cachedFile = itemDirectory.appendingPathComponent(
            RecentDocumentThumbnailCachePolicy.fileName(stamp: stamp)
        )
        if let data = try? Data(contentsOf: cachedFile),
           let image = NSImage(data: data) {
            memory.setObject(image, forKey: key)
            return image
        }

        guard let url else { return nil }
        let didStartScope = url.startAccessingSecurityScopedResource()
        defer { if didStartScope { url.stopAccessingSecurityScopedResource() } }

        guard let data = await renderer.render(url: url) else { return nil }

        // A new stamp supersedes every older preview for the same item.
        try? fileManager.removeItem(at: itemDirectory)
        try? fileManager.createDirectory(
            at: itemDirectory, withIntermediateDirectories: true
        )
        try? data.write(to: cachedFile, options: .atomic)
        guard let image = NSImage(data: data) else { return nil }
        memory.setObject(image, forKey: key)
        return image
    }

    /// Drops previews whose recent entry was removed or cleared.
    func prune(keeping ids: Set<UUID>) {
        let stale = RecentDocumentThumbnailCachePolicy.staleDirectories(
            in: directory, keeping: ids, fileManager: fileManager
        )
        for url in stale {
            try? fileManager.removeItem(at: url)
        }
    }

    private static func stamp(for url: URL?, fileManager: FileManager) -> String {
        guard let url,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let date = attributes[.modificationDate] as? Date
        else {
            return RecentDocumentThumbnailCachePolicy.stamp(
                modificationDate: nil, fileSize: nil
            )
        }
        return RecentDocumentThumbnailCachePolicy.stamp(
            modificationDate: date, fileSize: size.int64Value
        )
    }
}

/// PDFKit objects are created and consumed entirely inside this actor, so no
/// non-Sendable AppKit object crosses a concurrency boundary.
private actor FirstPageRenderer {
    func render(url: URL) -> Data? {
        guard let document = PDFDocument(url: url),
              let page = document.page(at: 0)
        else { return nil }

        let thumbnail = page.thumbnail(
            of: NSSize(width: 208, height: 272), for: .cropBox
        )
        guard let tiff = thumbnail.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
