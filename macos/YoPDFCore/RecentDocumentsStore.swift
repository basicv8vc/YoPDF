import Combine
import Foundation

/// The navigation and zoom values YoPDF restores when a PDF is opened again.
public struct RecentReadingPosition: Codable, Equatable, Sendable {
    public var pageIndex: Int
    public var zoomScale: Double
    public var usesAutomaticScaling: Bool

    public init(pageIndex: Int = 0, zoomScale: Double = 1, usesAutomaticScaling: Bool = true) {
        self.pageIndex = pageIndex
        self.zoomScale = zoomScale
        self.usesAutomaticScaling = usesAutomaticScaling
    }
}

/// One entry in the small, local Open Recent list.
///
/// The bookmark is the authority for reopening a file. `lastKnownPath` is only
/// used to match the reading position after a bookmark follows a moved file.
public struct RecentDocument: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var displayName: String
    public var bookmarkData: Data
    public var lastOpenedAt: Date
    public var lastKnownPath: String
    public var readingPosition: RecentReadingPosition

    public init(
        id: UUID = UUID(),
        displayName: String,
        bookmarkData: Data,
        lastOpenedAt: Date = .now,
        lastKnownPath: String,
        readingPosition: RecentReadingPosition = RecentReadingPosition()
    ) {
        self.id = id
        self.displayName = displayName
        self.bookmarkData = bookmarkData
        self.lastOpenedAt = lastOpenedAt
        self.lastKnownPath = lastKnownPath
        self.readingPosition = readingPosition
    }
}

public enum RecentDocumentsError: Error, Equatable {
    case itemNoLongerAvailable
    case bookmarkCouldNotBeResolved
    case bookmarkDidNotResolveToFile
    case bookmarkCouldNotBeCreated
    case storageUnavailable
}

/// Stores recent PDFs and reading positions in UserDefaults, using security-
/// scoped bookmarks instead of a document database. The last-known path is a
/// matching hint; it does not grant access to the file.
@MainActor
public final class RecentDocumentsStore: ObservableObject {

    public static let shared = RecentDocumentsStore()
    public static let maximumCount = 10

    private static let storageKey = "dev.yopdf.recentDocuments.v1"
    private static let storageVersion = 1

    @Published public private(set) var items: [RecentDocument] = []

    /// Allows the File menu to recover from an unreadable value without
    /// silently overwriting it when the next PDF opens.
    public var canClear: Bool { !items.isEmpty || hasUnreadableStoredValue }

    private struct StoredValue: Codable {
        let version: Int
        let items: [RecentDocument]
    }

    private let defaults: UserDefaults
    private let bookmarkDataProvider: @MainActor (URL) throws -> Data
    private var resolvedURLs: [UUID: URL] = [:]
    private var staleBookmarkIDs = Set<UUID>()
    /// An unreadable value is preserved until the user explicitly clears it;
    /// opening another PDF must not replace the only copy of unknown data.
    private var hasUnreadableStoredValue = false

    public init(
        defaults: UserDefaults = .standard,
        bookmarkDataProvider: (@MainActor (URL) throws -> Data)? = nil
    ) {
        self.defaults = defaults
        self.bookmarkDataProvider = bookmarkDataProvider ?? { url in
            try url.bookmarkData(options: [.withSecurityScope])
        }
        loadStoredValue()
    }

    /// Resolves a bookmark without touching the file. `DocumentStore.open`
    /// starts the security scope before it checks or reads the resolved URL.
    public func resolveURL(for item: RecentDocument) throws -> URL {
        guard let stored = items.first(where: { $0.id == item.id }) else {
            throw RecentDocumentsError.itemNoLongerAvailable
        }

        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: stored.bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw RecentDocumentsError.bookmarkCouldNotBeResolved
        }

        guard url.isFileURL else {
            throw RecentDocumentsError.bookmarkDidNotResolveToFile
        }

        resolvedURLs[stored.id] = url.standardizedFileURL
        if isStale {
            // Refresh only after DocumentSession has acquired the resolved
            // URL's scope; bookmark creation may touch the resource.
            staleBookmarkIDs.insert(stored.id)
        }
        return url
    }

    /// Adds a successfully opened file, or moves its existing entry to the top.
    /// The caller invokes this only while its DocumentSession still owns access.
    @discardableResult
    public func recordOpened(_ url: URL) -> Bool {
        guard url.isFileURL, !hasUnreadableStoredValue else { return false }

        let standardizedURL = url.standardizedFileURL
        let path = standardizedURL.path
        let previousIndex = items.firstIndex { item in
            item.lastKnownPath == path || resolvedURLs[item.id]?.path == path
        }
        let previous = previousIndex.map { items[$0] }
        let previousBookmarkWasStale = previous.map { staleBookmarkIDs.contains($0.id) } ?? false

        let bookmark: Data
        do {
            bookmark = try bookmarkDataProvider(url)
        } catch {
            // If an old, non-stale bookmark still exists, keep it rather than
            // losing an otherwise valid recent entry. A stale one must not be
            // retained after its resolved URL has been opened successfully.
            guard let previous, !previousBookmarkWasStale else { return false }
            bookmark = previous.bookmarkData
        }
        if let previous { staleBookmarkIDs.remove(previous.id) }

        let entry = RecentDocument(
            id: previous?.id ?? UUID(),
            displayName: standardizedURL.lastPathComponent,
            bookmarkData: bookmark,
            lastOpenedAt: .now,
            lastKnownPath: path,
            readingPosition: previous?.readingPosition ?? RecentReadingPosition()
        )

        items.removeAll { $0.id == entry.id }
        items.insert(entry, at: 0)
        if items.count > Self.maximumCount {
            items = Array(items.prefix(Self.maximumCount))
        }

        resolvedURLs[entry.id] = standardizedURL
        let retainedIDs = Set(items.map(\.id))
        resolvedURLs = resolvedURLs.filter { retainedIDs.contains($0.key) }
        staleBookmarkIDs.formIntersection(retainedIDs)
        persist()
        return true
    }

    /// Replaces a broken recent bookmark after the selected PDF has been
    /// validated and opened by `PDFDocumentModel`. A nil URL represents a
    /// cancelled file selection and leaves the stored entry untouched.
    ///
    /// The bookmark is created before any stored state changes. Callers must
    /// keep the selected URL's security scope active until this method returns.
    @discardableResult
    public func relink(_ item: RecentDocument, to selectedURL: URL?) throws -> Bool {
        guard let selectedURL else { return false }
        guard !hasUnreadableStoredValue else { throw RecentDocumentsError.storageUnavailable }
        guard selectedURL.isFileURL else { throw RecentDocumentsError.bookmarkDidNotResolveToFile }
        guard let previous = items.first(where: { $0.id == item.id }) else {
            throw RecentDocumentsError.itemNoLongerAvailable
        }

        let url = selectedURL.standardizedFileURL
        let bookmark: Data
        do {
            bookmark = try bookmarkDataProvider(selectedURL)
        } catch {
            throw RecentDocumentsError.bookmarkCouldNotBeCreated
        }

        let path = url.path
        let duplicateIDs = Set(items.compactMap { candidate -> UUID? in
            guard candidate.id != previous.id else { return nil }
            guard candidate.lastKnownPath == path || resolvedURLs[candidate.id]?.path == path else {
                return nil
            }
            return candidate.id
        })
        let updated = RecentDocument(
            id: previous.id,
            displayName: url.lastPathComponent,
            bookmarkData: bookmark,
            lastOpenedAt: .now,
            lastKnownPath: path,
            readingPosition: previous.readingPosition
        )

        items.removeAll { $0.id == previous.id || duplicateIDs.contains($0.id) }
        items.insert(updated, at: 0)
        if items.count > Self.maximumCount {
            items = Array(items.prefix(Self.maximumCount))
        }

        resolvedURLs[previous.id] = url
        for id in duplicateIDs {
            resolvedURLs[id] = nil
        }
        let retainedIDs = Set(items.map(\.id))
        resolvedURLs = resolvedURLs.filter { retainedIDs.contains($0.key) }
        staleBookmarkIDs.remove(previous.id)
        staleBookmarkIDs.subtract(duplicateIDs)
        staleBookmarkIDs.formIntersection(retainedIDs)
        persist()
        return true
    }

    /// The saved position for a file, including a bookmark-resolved moved file.
    public func readingPosition(for url: URL) -> RecentReadingPosition? {
        let path = url.standardizedFileURL.path
        return items.first { item in
            item.lastKnownPath == path || resolvedURLs[item.id]?.path == path
        }?.readingPosition
    }

    /// The current position for an entry, even when the selected relink target
    /// has a different path from the bookmark that originally pointed to it.
    public func readingPosition(for item: RecentDocument) -> RecentReadingPosition? {
        items.first { $0.id == item.id }?.readingPosition
    }

    /// Saves the latest page and zoom values for an already-open recent item.
    public func updateReadingPosition(_ position: RecentReadingPosition, for url: URL) {
        guard !hasUnreadableStoredValue, url.isFileURL else { return }
        let path = url.standardizedFileURL.path
        guard let index = items.firstIndex(where: { item in
            item.lastKnownPath == path || resolvedURLs[item.id]?.path == path
        }) else { return }

        guard items[index].readingPosition != position else { return }
        items[index].readingPosition = position
        persist()
    }

    public func remove(_ item: RecentDocument) {
        items.removeAll { $0.id == item.id }
        resolvedURLs[item.id] = nil
        staleBookmarkIDs.remove(item.id)
        persist()
    }

    public func clear() {
        items.removeAll()
        resolvedURLs.removeAll()
        staleBookmarkIDs.removeAll()
        hasUnreadableStoredValue = false
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func loadStoredValue() {
        guard let value = defaults.object(forKey: Self.storageKey) else { return }
        guard let data = value as? Data else {
            hasUnreadableStoredValue = true
            return
        }
        do {
            let stored = try PropertyListDecoder().decode(StoredValue.self, from: data)
            guard stored.version == Self.storageVersion else {
                hasUnreadableStoredValue = true
                return
            }
            items = Array(stored.items.prefix(Self.maximumCount))
        } catch {
            hasUnreadableStoredValue = true
        }
    }

    private func persist() {
        guard !hasUnreadableStoredValue else { return }
        let stored = StoredValue(version: Self.storageVersion, items: items)
        guard let data = try? PropertyListEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
