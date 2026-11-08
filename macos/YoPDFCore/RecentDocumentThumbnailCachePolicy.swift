import Foundation

/// Naming and invalidation rules for cached recent-document thumbnails.
///
/// Kept free of AppKit and PDFKit so the rules can be unit tested without a
/// window. Each recent item owns a subdirectory named after its UUID; inside
/// it, a file name derived from the source file's modification date and size
/// acts as a content stamp. A changed file simply misses the old stamp.
public enum RecentDocumentThumbnailCachePolicy {

    public static func directoryName(for id: UUID) -> String {
        id.uuidString
    }

    /// A file-name-safe stamp for a source file's current state. Missing
    /// attributes produce a weak stamp: the preview is still cached, but a
    /// later readable inspection replaces it.
    public static func stamp(modificationDate: Date?, fileSize: Int64?) -> String {
        guard let modificationDate, let fileSize else { return "unknown" }
        return "\(Int(modificationDate.timeIntervalSince1970))-\(fileSize)"
    }

    public static func fileName(stamp: String) -> String {
        "\(stamp).png"
    }

    /// Subdirectories that no longer belong to a stored recent item. Files
    /// that are not directories are left alone.
    public static func staleDirectories(
        in directory: URL,
        keeping ids: Set<UUID>,
        fileManager: FileManager = .default
    ) -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents.filter { url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true
            else { return false }
            guard let id = UUID(uuidString: url.lastPathComponent) else { return true }
            return !ids.contains(id)
        }
    }
}
