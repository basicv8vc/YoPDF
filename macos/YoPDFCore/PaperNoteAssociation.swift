import Foundation

// MARK: - Bookmark & Authorization Abstractions

/// Result of resolving a persisted security-scoped bookmark.
public struct ResolvedBookmark: Equatable, Sendable {
    public let url: URL
    public let isStale: Bool

    public init(url: URL, isStale: Bool) {
        self.url = url
        self.isStale = isStale
    }
}

/// Determines whether YoPDF holds explicit authorization to create files inside
/// a directory.
///
/// Access to a PDF file inside a directory must **never** be treated as
/// automatic permission to create or modify sibling files in that directory.
public protocol NoteLocationAuthorizing: Sendable {
    func isDirectoryAuthorizedForWriting(_ directoryURL: URL) -> Bool
}

/// Default location authorizer.
///
/// - In a sandboxed process (or when `isSandboxedOverride` is `true`), only
///   directories covered by an explicit directory grant (such as a user-chosen
///   folder or Research Notebook Directory) are authorized.
/// - Outside a sandbox, a directory must still exist as a writable directory on
///   the filesystem.
public struct SystemNoteLocationAuthorizer: NoteLocationAuthorizing {
    private let isSandboxedOverride: Bool?
    private let authorizedDirectoriesProvider: @Sendable () -> [URL]

    public init(
        isSandboxed: Bool? = nil,
        authorizedDirectoriesProvider: @escaping @Sendable () -> [URL] = { [] }
    ) {
        self.isSandboxedOverride = isSandboxed
        self.authorizedDirectoriesProvider = authorizedDirectoriesProvider
    }

    public var isSandboxed: Bool {
        if let isSandboxedOverride {
            return isSandboxedOverride
        }
        return ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    public func isDirectoryAuthorizedForWriting(_ directoryURL: URL) -> Bool {
        guard directoryURL.isFileURL else { return false }
        let targetPath = directoryURL.resolvingSymlinksInPath().standardizedFileURL.path

        let authorized = authorizedDirectoriesProvider().contains { allowed in
            let allowedPath = allowed.resolvingSymlinksInPath().standardizedFileURL.path
            if targetPath == allowedPath { return true }
            let prefix = allowedPath.hasSuffix("/") ? allowedPath : allowedPath + "/"
            return targetPath.hasPrefix(prefix)
        }

        if authorized {
            return true
        }
        if isSandboxed {
            return false
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetPath, isDirectory: &isDir),
              isDir.boolValue else {
            return false
        }
        return FileManager.default.isWritableFile(atPath: targetPath)
    }
}

/// Explicit allowlist authorizer for deterministic sandbox testing and folder-grant tracking.
public final class ExplicitNoteLocationAuthorizer: NoteLocationAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var authorizedPaths: Set<String>

    public init(authorizedDirectories: [URL] = []) {
        self.authorizedPaths = Set(
            authorizedDirectories.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        )
    }

    public func authorize(directory: URL) {
        guard directory.isFileURL else { return }
        let path = directory.resolvingSymlinksInPath().standardizedFileURL.path
        _ = lock.withLock { authorizedPaths.insert(path) }
    }

    public func revoke(directory: URL) {
        let path = directory.resolvingSymlinksInPath().standardizedFileURL.path
        _ = lock.withLock { authorizedPaths.remove(path) }
    }

    public func isDirectoryAuthorizedForWriting(_ directoryURL: URL) -> Bool {
        guard directoryURL.isFileURL else { return false }
        let targetPath = directoryURL.resolvingSymlinksInPath().standardizedFileURL.path
        return lock.withLock {
            authorizedPaths.contains { allowedPath in
                if targetPath == allowedPath { return true }
                let prefix = allowedPath.hasSuffix("/") ? allowedPath : allowedPath + "/"
                return targetPath.hasPrefix(prefix)
            }
        }
    }
}

// MARK: - PaperNoteAssociation

/// Persistent association between a local PDF paper and a standalone Markdown
/// research note (`<paper-name>.notes.md` or user-selected `.md` file).
///
/// The Markdown file is the sole source of truth for paper notes; notes are
/// never embedded inside PDF metadata or binary annotations.
public struct PaperNoteAssociation: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let pdfResourceID: ResourceID
    public var pdfURL: URL
    public var pdfBookmarkData: Data?
    public var pdfContentHash: String

    public var markdownResourceID: ResourceID
    public var markdownURL: URL
    public var markdownBookmarkData: Data?

    public let createdAt: Date
    public var lastModifiedAt: Date

    public init(
        id: UUID = UUID(),
        pdfResourceID: ResourceID,
        pdfURL: URL,
        pdfBookmarkData: Data?,
        pdfContentHash: String,
        markdownResourceID: ResourceID,
        markdownURL: URL,
        markdownBookmarkData: Data?,
        createdAt: Date = Date(),
        lastModifiedAt: Date = Date()
    ) {
        self.id = id
        self.pdfResourceID = pdfResourceID
        self.pdfURL = pdfURL
        self.pdfBookmarkData = pdfBookmarkData
        self.pdfContentHash = pdfContentHash
        self.markdownResourceID = markdownResourceID
        self.markdownURL = markdownURL
        self.markdownBookmarkData = markdownBookmarkData
        self.createdAt = createdAt
        self.lastModifiedAt = lastModifiedAt
    }
}

// MARK: - Research Notebook Directory

/// Optional user-selected directory (such as an Obsidian vault or notes folder)
/// where newly created paper notes may be placed instead of beside the PDF.
public struct ResearchNotebookDirectory: Equatable, Sendable, Codable {
    public var url: URL
    public var bookmarkData: Data?
    public var updatedAt: Date

    public init(url: URL, bookmarkData: Data?, updatedAt: Date = Date()) {
        self.url = url
        self.bookmarkData = bookmarkData
        self.updatedAt = updatedAt
    }
}

public enum NotebookDirectoryResolution: Equatable, Sendable {
    case notConfigured
    case resolved(URL, refreshedBookmark: Bool)
    case missingDirectory(lastKnownURL: URL)
    case bookmarkUnresolvable(lastKnownURL: URL)
}

// MARK: - Planning, Resolution & Errors

public enum NoteCreationLocationPreference: Equatable, Sendable {
    /// Uses the configured Research Notebook Directory if available; otherwise
    /// defaults to `<paper-name>.notes.md` beside the PDF.
    case automatic
    /// Places `<paper-name>.notes.md` alongside the PDF when writable and authorized.
    case besidePDF
    /// Places `<paper-name>.notes.md` inside the configured Research Notebook Directory.
    case notebookDirectory
}

public enum NoteCreationPlan: Equatable, Sendable {
    /// An association already exists and its Markdown note resolves cleanly.
    case alreadyAssociated(PaperNoteAssociation, resolvedMarkdownURL: URL)
    /// An association exists, but its note file could not be resolved or is missing.
    case brokenAssociation(PaperNoteAssociation)
    /// Safe to create a brand-new Markdown note at `targetURL`.
    case readyToCreate(targetURL: URL)
    /// A file already exists at `existingURL`. Never overwrite; prompt the user to
    /// link existing, create with another filename (`suggestedAlternativeURL`), or choose a file.
    case existingNoteCollision(existingURL: URL, suggestedAlternativeURL: URL)
    /// The target directory is not authorized for sibling writes; prompt with a save/folder picker.
    case locationAuthorizationRequired(suggestedURL: URL)
    /// The target directory exists and is authorized, but is not writable (e.g. read-only).
    case directoryNotWritable(URL)
    /// The requested Research Notebook Directory is not configured or cannot be resolved.
    case notebookDirectoryUnavailable(NotebookDirectoryResolution)
}

public enum PDFResourceResolution: Equatable, Sendable {
    case resolved(URL, refreshedBookmark: Bool)
    /// Bookmark resolution failed, and a single candidate in the search directories
    /// matched `pdfContentHash`.
    case singleCandidate(URL)
    /// Bookmark resolution failed, and multiple candidates matched `pdfContentHash`;
    /// explicit user relinking is required rather than guessing.
    case ambiguousCandidates([URL])
    case missing(lastKnownURL: URL)
}

public enum MarkdownResourceResolution: Equatable, Sendable {
    case resolved(URL, refreshedBookmark: Bool)
    case missing(lastKnownURL: URL)
    /// The association has no security-scoped bookmark for the Markdown file
    /// and cannot be safely restored without explicit user relinking.
    case bookmarkMissing(lastKnownURL: URL)
}

public struct AssociationResolutionResult: Equatable, Sendable {
    public let association: PaperNoteAssociation
    public let pdfResolution: PDFResourceResolution
    public let markdownResolution: MarkdownResourceResolution
    public let didRefreshBookmarks: Bool

    public init(
        association: PaperNoteAssociation,
        pdfResolution: PDFResourceResolution,
        markdownResolution: MarkdownResourceResolution,
        didRefreshBookmarks: Bool
    ) {
        self.association = association
        self.pdfResolution = pdfResolution
        self.markdownResolution = markdownResolution
        self.didRefreshBookmarks = didRefreshBookmarks
    }
}

public enum PaperNoteAssociationError: Error, Equatable, Sendable {
    case notAFileURL(URL)
    case unsupportedMarkdownType(String)
    case pdfMissingOrUnreadable(URL)
    case noteFileMissingOrUnreadable(URL)
    case invalidMarkdownUTF8(URL)
    case noteFileAlreadyExists(URL)
    case directoryNotAuthorized(URL)
    case directoryNotWritable(URL)
    case directoryMissing(URL)
    case notebookDirectoryUnavailable(NotebookDirectoryResolution)
    case associationNotFound(UUID)
    case bookmarkCreationFailed(URL)
    /// The Markdown note file was safely created on disk, but creating a
    /// security-scoped bookmark for it failed. The file is preserved on disk
    /// and must be explicitly linked/relinked before restoration can be trusted.
    case noteCreatedButBookmarkFailed(createdNoteURL: URL, pdfURL: URL, reason: String)
    /// The Markdown note file was safely created on disk and bookmarked, but
    /// persisting `associations.json` failed. The file is preserved on disk and
    /// `associations` in memory was not mutated.
    case noteCreatedButPersistenceFailed(pendingAssociation: PaperNoteAssociation, reason: String)
    case storageCorrupted
    case storageWriteFailed(String)
    case creationFailed(MarkdownLoadError)
}

extension PaperNoteAssociationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .notAFileURL(url):
            return "“\(url.absoluteString)” is not a local file URL."
        case let .unsupportedMarkdownType(ext):
            return MarkdownLoadError.unsupportedType(ext).errorDescription
        case let .pdfMissingOrUnreadable(url):
            return "The PDF “\(url.lastPathComponent)” could not be accessed."
        case let .noteFileMissingOrUnreadable(url):
            return "The Markdown note “\(url.lastPathComponent)” could not be accessed."
        case let .invalidMarkdownUTF8(url):
            return "“\(url.lastPathComponent)” is not valid UTF-8 Markdown text."
        case let .noteFileAlreadyExists(url):
            return "A note file named “\(url.lastPathComponent)” already exists."
        case let .directoryNotAuthorized(url):
            return "YoPDF does not have permission to write files inside “\(url.lastPathComponent)”."
        case let .directoryNotWritable(url):
            return "“\(url.lastPathComponent)” is read-only or not writable."
        case let .directoryMissing(url):
            return "The folder “\(url.lastPathComponent)” could not be found."
        case .notebookDirectoryUnavailable:
            return "The configured Research Notebook Directory is unavailable."
        case .associationNotFound:
            return "The paper-note association could not be found."
        case let .bookmarkCreationFailed(url):
            return "Could not create a security-scoped bookmark for “\(url.lastPathComponent)”."
        case let .noteCreatedButBookmarkFailed(createdNoteURL, _, reason):
            return "“\(createdNoteURL.lastPathComponent)” was created, but a security-scoped bookmark could not be saved (\(reason)). Link or relink the note to associate it."
        case let .noteCreatedButPersistenceFailed(pendingAssociation, reason):
            return "“\(pendingAssociation.markdownURL.lastPathComponent)” was created, but saving the association failed (\(reason))."
        case .storageCorrupted:
            return "The saved paper-note associations file could not be read and was left untouched."
        case let .storageWriteFailed(reason):
            return "Could not save paper-note associations: \(reason)"
        case let .creationFailed(loadError):
            return loadError.errorDescription
        }
    }
}

// MARK: - PaperNoteAssociationStore

/// Manages persistent associations between PDFs and standalone Markdown paper notes,
/// optional Research Notebook Directory configuration, collision detection, and
/// security-scoped bookmark refresh / explicit relinking.
@MainActor
public final class PaperNoteAssociationStore: ObservableObject {

    public static let defaultStorageURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("YoPDF", isDirectory: true)
            .appendingPathComponent("associations.json")
    }()

    private static let storageVersion = 1
    private static let notebookDefaultsKey = "dev.yopdf.researchNotebookDirectory.v1"
    private static let notebookStorageVersion = 1

    private struct StoredAssociations: Codable {
        let version: Int
        let associations: [PaperNoteAssociation]
    }

    private struct StoredNotebookDirectory: Codable {
        let version: Int
        let directory: ResearchNotebookDirectory
    }

    @Published public private(set) var associations: [PaperNoteAssociation] = []
    @Published public private(set) var notebookDirectory: ResearchNotebookDirectory?
    @Published public private(set) var hasUnreadableAssociationsStorage: Bool = false
    @Published public private(set) var hasUnreadableNotebookSetting: Bool = false

    private let storageURL: URL
    private let defaults: UserDefaults
    private let access: any SecurityScopeAccessing
    private let io: any DocumentStoreIO
    private let locationAuthorizer: any NoteLocationAuthorizing
    private let bookmarkDataProvider: @MainActor (URL) throws -> Data
    private let bookmarkResolver: @MainActor (Data) throws -> ResolvedBookmark
    private let associationsDataWriter: @Sendable (Data, URL) throws -> Void
    private let associationsRemover: @Sendable (URL) throws -> Void

    public init(
        storageURL: URL = PaperNoteAssociationStore.defaultStorageURL,
        defaults: UserDefaults = .standard,
        access: any SecurityScopeAccessing = SystemSecurityScopeAccess(),
        io: any DocumentStoreIO = SystemDocumentStoreIO(),
        locationAuthorizer: (any NoteLocationAuthorizing)? = nil,
        bookmarkDataProvider: (@MainActor (URL) throws -> Data)? = nil,
        bookmarkResolver: (@MainActor (Data) throws -> ResolvedBookmark)? = nil,
        associationsDataWriter: (@Sendable (Data, URL) throws -> Void)? = nil,
        associationsRemover: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.storageURL = storageURL
        self.defaults = defaults
        self.access = access
        self.io = io
        self.locationAuthorizer = locationAuthorizer ?? SystemNoteLocationAuthorizer()
        self.bookmarkDataProvider = bookmarkDataProvider ?? { url in
            try url.bookmarkData(options: [.withSecurityScope])
        }
        self.bookmarkResolver = bookmarkResolver ?? { data in
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return ResolvedBookmark(url: url, isStale: isStale)
        }
        self.associationsDataWriter = associationsDataWriter ?? { data, url in
            try data.write(to: url, options: [.atomic])
        }
        self.associationsRemover = associationsRemover ?? { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        }

        loadAssociations()
        loadNotebookDirectory()
    }

    // MARK: - Default Naming

    /// Default note filename: `<paper-name>.notes.md`.
    public static func defaultNoteFilename(forPDF pdfURL: URL) -> String {
        let stem = pdfURL.deletingPathExtension().lastPathComponent
        let safeStem = stem.isEmpty ? "Untitled" : stem
        return "\(safeStem).notes.md"
    }

    /// Generates a non-colliding candidate filename such as `<paper-name>.notes 2.md`.
    public func nextAvailableNoteURL(near defaultNoteURL: URL) -> URL {
        let directory = defaultNoteURL.deletingLastPathComponent()
        let ext = defaultNoteURL.pathExtension
        let stemWithoutExt = defaultNoteURL.deletingPathExtension().lastPathComponent

        var suffix = 2
        while suffix < 10_000 {
            let candidateName = ext.isEmpty ? "\(stemWithoutExt) \(suffix)" : "\(stemWithoutExt) \(suffix).\(ext)"
            let candidateURL = directory.appendingPathComponent(candidateName)
            if let status = try? io.status(of: candidateURL), !status.exists, !status.isSymbolicLink {
                return candidateURL
            }
            suffix += 1
        }
        return directory.appendingPathComponent("\(stemWithoutExt)-\(UUID().uuidString.prefix(8)).\(ext.isEmpty ? "md" : ext)")
    }

    // MARK: - Research Notebook Directory (Obsidian Vault)

    @discardableResult
    public func setNotebookDirectory(_ url: URL) throws -> ResearchNotebookDirectory {
        guard !hasUnreadableNotebookSetting else {
            throw PaperNoteAssociationError.storageCorrupted
        }
        guard url.isFileURL else {
            throw PaperNoteAssociationError.notAFileURL(url)
        }

        let standardized = url.standardizedFileURL
        let lease = SecurityScopeLease(url: standardized, access: access)
        defer { lease.release() }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw PaperNoteAssociationError.directoryMissing(standardized)
        }

        let bookmark: Data
        do {
            bookmark = try bookmarkDataProvider(standardized)
        } catch {
            throw PaperNoteAssociationError.bookmarkCreationFailed(standardized)
        }

        let config = ResearchNotebookDirectory(url: standardized, bookmarkData: bookmark, updatedAt: Date())
        notebookDirectory = config
        persistNotebookDirectory()
        return config
    }

    public func clearNotebookDirectory() {
        notebookDirectory = nil
        hasUnreadableNotebookSetting = false
        defaults.removeObject(forKey: Self.notebookDefaultsKey)
    }

    public func resolveNotebookDirectory() -> NotebookDirectoryResolution {
        guard let current = notebookDirectory else {
            return .notConfigured
        }

        guard let bookmarkData = current.bookmarkData else {
            let lease = SecurityScopeLease(url: current.url, access: access)
            defer { lease.release() }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: current.url.path, isDirectory: &isDir), isDir.boolValue {
                return .resolved(current.url, refreshedBookmark: false)
            }
            return .missingDirectory(lastKnownURL: current.url)
        }

        let resolved: ResolvedBookmark
        do {
            resolved = try bookmarkResolver(bookmarkData)
        } catch {
            return .bookmarkUnresolvable(lastKnownURL: current.url)
        }

        guard resolved.url.isFileURL else {
            return .bookmarkUnresolvable(lastKnownURL: current.url)
        }

        let standardized = resolved.url.standardizedFileURL
        let lease = SecurityScopeLease(url: standardized, access: access)
        defer { lease.release() }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDir),
              isDir.boolValue else {
            return .missingDirectory(lastKnownURL: standardized)
        }

        var refreshed = false
        if resolved.isStale || standardized != current.url.standardizedFileURL {
            var updatedBookmark = current.bookmarkData
            if resolved.isStale, let freshData = try? bookmarkDataProvider(standardized) {
                updatedBookmark = freshData
                refreshed = true
            }
            notebookDirectory = ResearchNotebookDirectory(
                url: standardized,
                bookmarkData: updatedBookmark,
                updatedAt: Date()
            )
            persistNotebookDirectory()
        }

        return .resolved(standardized, refreshedBookmark: refreshed)
    }

    // MARK: - Planning & Collision Detection

    /// Evaluates what should happen when the user initiates Paper Note creation/opening
    /// for `pdfURL`. Never creates or overwrites files.
    public func planDefaultNoteCreation(
        forPDF pdfURL: URL,
        locationPreference: NoteCreationLocationPreference = .automatic
    ) -> NoteCreationPlan {
        if let existing = association(forPDF: pdfURL) {
            let resolved = resolveAssociation(existing)
            switch resolved.markdownResolution {
            case let .resolved(markdownURL, _):
                return .alreadyAssociated(resolved.association, resolvedMarkdownURL: markdownURL)
            case .missing, .bookmarkMissing:
                return .brokenAssociation(resolved.association)
            }
        }

        let filename = Self.defaultNoteFilename(forPDF: pdfURL)

        switch locationPreference {
        case .notebookDirectory:
            return planInNotebookDirectory(filename: filename)

        case .besidePDF:
            return planBesidePDF(pdfURL: pdfURL, filename: filename)

        case .automatic:
            if notebookDirectory != nil {
                return planInNotebookDirectory(filename: filename)
            }
            return planBesidePDF(pdfURL: pdfURL, filename: filename)
        }
    }

    private func planInNotebookDirectory(filename: String) -> NoteCreationPlan {
        let resolution = resolveNotebookDirectory()
        guard case let .resolved(notebookURL, _) = resolution else {
            return .notebookDirectoryUnavailable(resolution)
        }

        let lease = SecurityScopeLease(url: notebookURL, access: access)
        defer { lease.release() }

        guard FileManager.default.isWritableFile(atPath: notebookURL.path) else {
            return .directoryNotWritable(notebookURL)
        }

        let targetURL = notebookURL.appendingPathComponent(filename)
        return checkTargetCollision(at: targetURL)
    }

    private func planBesidePDF(pdfURL: URL, filename: String) -> NoteCreationPlan {
        let parentDirectory = pdfURL.deletingLastPathComponent().standardizedFileURL
        let targetURL = parentDirectory.appendingPathComponent(filename)

        guard locationAuthorizer.isDirectoryAuthorizedForWriting(parentDirectory) else {
            return .locationAuthorizationRequired(suggestedURL: targetURL)
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parentDirectory.path, isDirectory: &isDir),
              isDir.boolValue,
              FileManager.default.isWritableFile(atPath: parentDirectory.path) else {
            return .directoryNotWritable(parentDirectory)
        }

        return checkTargetCollision(at: targetURL)
    }

    private func checkTargetCollision(at targetURL: URL) -> NoteCreationPlan {
        if let status = try? io.status(of: targetURL), status.exists || status.isSymbolicLink {
            let alternative = nextAvailableNoteURL(near: targetURL)
            return .existingNoteCollision(existingURL: targetURL, suggestedAlternativeURL: alternative)
        }
        return .readyToCreate(targetURL: targetURL)
    }

    // MARK: - Create & Link

    /// Creates a new default `<paper-name>.notes.md` file according to
    /// `locationPreference` and persists its `PaperNoteAssociation`.
    ///
    /// Refuses if an existing file is detected, if the directory is not authorized,
    /// or if the directory is not writable.
    public func createDefaultNote(
        forPDF pdfURL: URL,
        initialContent: String = "",
        locationPreference: NoteCreationLocationPreference = .automatic,
        pdfResourceID: ResourceID = ResourceID(),
        markdownResourceID: ResourceID = ResourceID()
    ) throws -> (association: PaperNoteAssociation, session: MarkdownResourceSession) {
        let plan = planDefaultNoteCreation(forPDF: pdfURL, locationPreference: locationPreference)
        switch plan {
        case let .readyToCreate(targetURL):
            return try createNote(
                forPDF: pdfURL,
                at: targetURL,
                initialContent: initialContent,
                isUserSelectedDestination: false,
                pdfResourceID: pdfResourceID,
                markdownResourceID: markdownResourceID
            )
        case let .existingNoteCollision(existingURL, _):
            throw PaperNoteAssociationError.noteFileAlreadyExists(existingURL)
        case let .locationAuthorizationRequired(suggestedURL):
            throw PaperNoteAssociationError.directoryNotAuthorized(suggestedURL.deletingLastPathComponent())
        case let .directoryNotWritable(dirURL):
            throw PaperNoteAssociationError.directoryNotWritable(dirURL)
        case let .notebookDirectoryUnavailable(resolution):
            throw PaperNoteAssociationError.notebookDirectoryUnavailable(resolution)
        case let .alreadyAssociated(existing, _):
            throw PaperNoteAssociationError.noteFileAlreadyExists(existing.markdownURL)
        case let .brokenAssociation(existing):
            throw PaperNoteAssociationError.noteFileMissingOrUnreadable(existing.markdownURL)
        }
    }

    /// Creates a new Markdown note at `noteURL` (never overwriting an existing
    /// file) and associates it with `pdfURL`.
    ///
    /// By default (`isUserSelectedDestination == false`), the target directory
    /// must pass `locationAuthorizer` or lie inside the configured Research
    /// Notebook Directory. Callers passing a destination chosen explicitly in an
    /// `NSSavePanel` set `isUserSelectedDestination` to `true`.
    public func createNote(
        forPDF pdfURL: URL,
        at noteURL: URL,
        initialContent: String = "",
        isUserSelectedDestination: Bool = false,
        pdfResourceID: ResourceID = ResourceID(),
        markdownResourceID: ResourceID = ResourceID()
    ) throws -> (association: PaperNoteAssociation, session: MarkdownResourceSession) {
        guard !hasUnreadableAssociationsStorage else {
            throw PaperNoteAssociationError.storageCorrupted
        }
        guard pdfURL.isFileURL else {
            throw PaperNoteAssociationError.notAFileURL(pdfURL)
        }
        guard noteURL.isFileURL else {
            throw PaperNoteAssociationError.notAFileURL(noteURL)
        }
        guard MarkdownResourceSession.isSupportedMarkdownFile(noteURL) else {
            throw PaperNoteAssociationError.unsupportedMarkdownType(noteURL.pathExtension)
        }

        let targetDir = noteURL.deletingLastPathComponent().standardizedFileURL
        let notebookLease = activeNotebookLeaseIfCovering(noteURL)
        defer { notebookLease?.release() }

        if !isUserSelectedDestination && !isInsideConfiguredNotebookDirectory(noteURL) {
            guard locationAuthorizer.isDirectoryAuthorizedForWriting(targetDir) else {
                throw PaperNoteAssociationError.directoryNotAuthorized(targetDir)
            }
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetDir.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw PaperNoteAssociationError.directoryMissing(targetDir)
        }
        guard FileManager.default.isWritableFile(atPath: targetDir.path) else {
            throw PaperNoteAssociationError.directoryNotWritable(targetDir)
        }

        if let existingStatus = try? io.status(of: noteURL),
           existingStatus.exists || existingStatus.isSymbolicLink {
            throw PaperNoteAssociationError.noteFileAlreadyExists(noteURL)
        }

        // Validate PDF & create PDF bookmark BEFORE writing the new Markdown file.
        let (pdfHash, pdfBookmark) = try inspectAndBookmarkPDF(at: pdfURL)

        let session = MarkdownResourceSession(access: access, io: io)
        guard session.create(at: noteURL, initialContent: initialContent) else {
            let loadErr = session.lastError ?? .unreadable("Could not create “\(noteURL.lastPathComponent)”.")
            switch loadErr {
            case let .targetExists(url):
                throw PaperNoteAssociationError.noteFileAlreadyExists(url)
            case let .permissionDenied(url), let .readOnly(url):
                throw PaperNoteAssociationError.directoryNotWritable(url.deletingLastPathComponent())
            default:
                throw PaperNoteAssociationError.creationFailed(loadErr)
            }
        }

        let markdownBookmark: Data
        do {
            markdownBookmark = try bookmarkDataProvider(noteURL)
        } catch {
            session.close()
            throw PaperNoteAssociationError.noteCreatedButBookmarkFailed(
                createdNoteURL: noteURL.standardizedFileURL,
                pdfURL: pdfURL.standardizedFileURL,
                reason: error.localizedDescription
            )
        }

        let existing = association(forPDF: pdfURL)
        let now = Date()
        let association = PaperNoteAssociation(
            id: existing?.id ?? UUID(),
            pdfResourceID: existing?.pdfResourceID ?? pdfResourceID,
            pdfURL: pdfURL.standardizedFileURL,
            pdfBookmarkData: pdfBookmark,
            pdfContentHash: pdfHash,
            markdownResourceID: markdownResourceID,
            markdownURL: noteURL.standardizedFileURL,
            markdownBookmarkData: markdownBookmark,
            createdAt: existing?.createdAt ?? now,
            lastModifiedAt: now
        )

        let candidate = upserting(association, into: associations)
        do {
            try persistAssociations(candidate)
        } catch {
            session.close()
            throw PaperNoteAssociationError.noteCreatedButPersistenceFailed(
                pendingAssociation: association,
                reason: error.localizedDescription
            )
        }
        associations = candidate
        return (association, session)
    }

    /// Commits a pending association returned by `noteCreatedButPersistenceFailed`
    /// once association storage is writable again, without touching the created
    /// Markdown file on disk.
    @discardableResult
    public func commitPendingAssociation(_ pending: PaperNoteAssociation) throws -> PaperNoteAssociation {
        guard !hasUnreadableAssociationsStorage else {
            throw PaperNoteAssociationError.storageCorrupted
        }
        guard pending.markdownBookmarkData != nil else {
            throw PaperNoteAssociationError.bookmarkCreationFailed(pending.markdownURL)
        }

        let lease = SecurityScopeLease(url: pending.markdownURL, access: access)
        let exists = (try? io.status(of: pending.markdownURL))
            .map { $0.exists && $0.isRegularFile } ?? false
        lease.release()
        guard exists else {
            throw PaperNoteAssociationError.noteFileMissingOrUnreadable(pending.markdownURL)
        }

        var updated = pending
        updated.lastModifiedAt = Date()
        let candidate = upserting(updated, into: associations)
        try persistAssociations(candidate)
        associations = candidate
        return updated
    }

    /// Associates `pdfURL` with an existing UTF-8 Markdown file at `markdownURL`
    /// without modifying or overwriting `markdownURL`.
    @discardableResult
    public func linkExistingNote(
        forPDF pdfURL: URL,
        markdownURL: URL,
        pdfResourceID: ResourceID = ResourceID(),
        markdownResourceID: ResourceID = ResourceID()
    ) throws -> PaperNoteAssociation {
        guard !hasUnreadableAssociationsStorage else {
            throw PaperNoteAssociationError.storageCorrupted
        }
        guard pdfURL.isFileURL else {
            throw PaperNoteAssociationError.notAFileURL(pdfURL)
        }
        guard markdownURL.isFileURL else {
            throw PaperNoteAssociationError.notAFileURL(markdownURL)
        }
        guard MarkdownResourceSession.isSupportedMarkdownFile(markdownURL) else {
            throw PaperNoteAssociationError.unsupportedMarkdownType(markdownURL.pathExtension)
        }

        let (pdfHash, pdfBookmark) = try inspectAndBookmarkPDF(at: pdfURL)
        let markdownBookmark = try validateAndBookmarkMarkdown(at: markdownURL)

        let existing = association(forPDF: pdfURL)
        let now = Date()
        let updated = PaperNoteAssociation(
            id: existing?.id ?? UUID(),
            pdfResourceID: existing?.pdfResourceID ?? pdfResourceID,
            pdfURL: pdfURL.standardizedFileURL,
            pdfBookmarkData: pdfBookmark,
            pdfContentHash: pdfHash,
            markdownResourceID: markdownResourceID,
            markdownURL: markdownURL.standardizedFileURL,
            markdownBookmarkData: markdownBookmark,
            createdAt: existing?.createdAt ?? now,
            lastModifiedAt: now
        )

        let candidate = upserting(updated, into: associations)
        try persistAssociations(candidate)
        associations = candidate
        return updated
    }

    // MARK: - Lookup, Resolution & Relinking

    /// Finds the association for `pdfURL` by canonical path or resolved PDF bookmark.
    public func association(forPDF pdfURL: URL) -> PaperNoteAssociation? {
        guard pdfURL.isFileURL else { return nil }
        let targetCanonical = pdfURL.resolvingSymlinksInPath().standardizedFileURL

        if let direct = associations.first(where: {
            $0.pdfURL.resolvingSymlinksInPath().standardizedFileURL == targetCanonical
        }) {
            return direct
        }

        for entry in associations {
            guard let bookmark = entry.pdfBookmarkData,
                  let resolved = try? bookmarkResolver(bookmark) else {
                continue
            }
            if resolved.url.resolvingSymlinksInPath().standardizedFileURL == targetCanonical {
                return entry
            }
        }
        return nil
    }

    /// Returns associations whose recorded `pdfContentHash` matches `hash`.
    public func associations(matchingPDFHash hash: String) -> [PaperNoteAssociation] {
        associations.filter { $0.pdfContentHash == hash }
    }

    /// Resolves both PDF and Markdown bookmarks for an association, refreshing
    /// stale bookmarks while holding security-scoped access.
    ///
    /// - Note: If the PDF bookmark cannot be resolved, `pdfContentHash` is used
    ///   as a diagnostic candidate identifier within `candidatePDFSearchDirectories`.
    ///   Markdown recovery never guesses by hash and relies strictly on its
    ///   bookmark or explicit user relinking.
    @discardableResult
    public func resolveAssociation(
        _ association: PaperNoteAssociation,
        candidatePDFSearchDirectories: [URL] = []
    ) -> AssociationResolutionResult {
        var updated = associations.first(where: { $0.id == association.id }) ?? association
        var didUpdateStoredRecord = false
        var didRefreshBookmarks = false

        // 1. Resolve PDF
        let pdfResolution: PDFResourceResolution
        if let pdfBookmark = updated.pdfBookmarkData,
           let resolvedPDF = try? bookmarkResolver(pdfBookmark),
           resolvedPDF.url.isFileURL {
            let candidateURL = resolvedPDF.url.standardizedFileURL
            let lease = SecurityScopeLease(url: candidateURL, access: access)
            let exists = (try? io.status(of: candidateURL))
                .map { $0.exists && $0.isRegularFile } ?? false

            if exists {
                var refreshed = false
                if resolvedPDF.isStale, let freshData = try? bookmarkDataProvider(candidateURL) {
                    updated.pdfBookmarkData = freshData
                    refreshed = true
                    didRefreshBookmarks = true
                    didUpdateStoredRecord = true
                }
                if candidateURL != updated.pdfURL.standardizedFileURL {
                    updated.pdfURL = candidateURL
                    didUpdateStoredRecord = true
                }
                lease.release()
                pdfResolution = .resolved(candidateURL, refreshedBookmark: refreshed)
            } else {
                lease.release()
                pdfResolution = findPDFCandidateResolution(
                    forHash: updated.pdfContentHash,
                    lastKnownURL: updated.pdfURL,
                    in: candidatePDFSearchDirectories
                )
            }
        } else {
            pdfResolution = findPDFCandidateResolution(
                forHash: updated.pdfContentHash,
                lastKnownURL: updated.pdfURL,
                in: candidatePDFSearchDirectories
            )
        }

        // 2. Resolve Markdown (strictly via bookmark; never hash-guessed)
        let markdownResolution: MarkdownResourceResolution
        if let mdBookmark = updated.markdownBookmarkData {
            if let resolvedMD = try? bookmarkResolver(mdBookmark),
               resolvedMD.url.isFileURL {
                let candidateURL = resolvedMD.url.standardizedFileURL
                let lease = SecurityScopeLease(url: candidateURL, access: access)
                let exists = (try? io.status(of: candidateURL))
                    .map { $0.exists && $0.isRegularFile } ?? false

                if exists {
                    var refreshed = false
                    if resolvedMD.isStale, let freshData = try? bookmarkDataProvider(candidateURL) {
                        updated.markdownBookmarkData = freshData
                        refreshed = true
                        didRefreshBookmarks = true
                        didUpdateStoredRecord = true
                    }
                    if candidateURL != updated.markdownURL.standardizedFileURL {
                        updated.markdownURL = candidateURL
                        didUpdateStoredRecord = true
                    }
                    lease.release()
                    markdownResolution = .resolved(candidateURL, refreshedBookmark: refreshed)
                } else {
                    lease.release()
                    markdownResolution = .missing(lastKnownURL: updated.markdownURL)
                }
            } else {
                markdownResolution = .missing(lastKnownURL: updated.markdownURL)
            }
        } else {
            markdownResolution = .bookmarkMissing(lastKnownURL: updated.markdownURL)
        }

        if didUpdateStoredRecord && !hasUnreadableAssociationsStorage {
            updated.lastModifiedAt = Date()
            if let index = associations.firstIndex(where: { $0.id == updated.id }) {
                var candidate = associations
                candidate[index] = updated
                if (try? persistAssociations(candidate)) != nil {
                    associations = candidate
                }
            }
        }

        return AssociationResolutionResult(
            association: updated,
            pdfResolution: pdfResolution,
            markdownResolution: markdownResolution,
            didRefreshBookmarks: didRefreshBookmarks
        )
    }

    @discardableResult
    public func relinkMarkdown(for associationID: UUID, to newMarkdownURL: URL) throws -> PaperNoteAssociation {
        guard !hasUnreadableAssociationsStorage else {
            throw PaperNoteAssociationError.storageCorrupted
        }
        guard newMarkdownURL.isFileURL else {
            throw PaperNoteAssociationError.notAFileURL(newMarkdownURL)
        }
        guard MarkdownResourceSession.isSupportedMarkdownFile(newMarkdownURL) else {
            throw PaperNoteAssociationError.unsupportedMarkdownType(newMarkdownURL.pathExtension)
        }
        guard let index = associations.firstIndex(where: { $0.id == associationID }) else {
            throw PaperNoteAssociationError.associationNotFound(associationID)
        }

        let bookmark = try validateAndBookmarkMarkdown(at: newMarkdownURL)

        var updated = associations[index]
        updated.markdownURL = newMarkdownURL.standardizedFileURL
        updated.markdownBookmarkData = bookmark
        updated.lastModifiedAt = Date()
        var candidate = associations
        candidate[index] = updated
        try persistAssociations(candidate)
        associations = candidate
        return updated
    }

    @discardableResult
    public func relinkPDF(for associationID: UUID, to newPDFURL: URL) throws -> PaperNoteAssociation {
        guard !hasUnreadableAssociationsStorage else {
            throw PaperNoteAssociationError.storageCorrupted
        }
        guard newPDFURL.isFileURL else {
            throw PaperNoteAssociationError.notAFileURL(newPDFURL)
        }
        guard let index = associations.firstIndex(where: { $0.id == associationID }) else {
            throw PaperNoteAssociationError.associationNotFound(associationID)
        }

        let (pdfHash, pdfBookmark) = try inspectAndBookmarkPDF(at: newPDFURL)

        var updated = associations[index]
        updated.pdfURL = newPDFURL.standardizedFileURL
        updated.pdfBookmarkData = pdfBookmark
        updated.pdfContentHash = pdfHash
        updated.lastModifiedAt = Date()
        var candidate = associations
        candidate[index] = updated
        try persistAssociations(candidate)
        associations = candidate
        return updated
    }

    /// Removes the association record without deleting the PDF or Markdown file.
    public func unlinkAssociation(id: UUID) throws {
        guard !hasUnreadableAssociationsStorage else {
            throw PaperNoteAssociationError.storageCorrupted
        }
        let candidate = associations.filter { $0.id != id }
        guard candidate.count != associations.count else {
            throw PaperNoteAssociationError.associationNotFound(id)
        }
        try persistAssociations(candidate)
        associations = candidate
    }

    /// Explicitly resets association storage (including unreadable storage) when
    /// the user chooses to recover. Deletes persisted storage before clearing
    /// in-memory state or `hasUnreadableAssociationsStorage`.
    public func clearAllAssociations() throws {
        do {
            try associationsRemover(storageURL)
        } catch {
            throw PaperNoteAssociationError.storageWriteFailed(error.localizedDescription)
        }
        associations.removeAll()
        hasUnreadableAssociationsStorage = false
    }

    // MARK: - Private Helpers

    private func inspectAndBookmarkPDF(at pdfURL: URL) throws -> (hash: String, bookmark: Data) {
        let standardized = pdfURL.standardizedFileURL
        let lease = SecurityScopeLease(url: standardized, access: access)
        defer { lease.release() }

        guard let status = try? io.status(of: standardized),
              status.exists,
              status.isRegularFile,
              !status.isCloudPlaceholder,
              let version = try? io.version(of: standardized) else {
            throw PaperNoteAssociationError.pdfMissingOrUnreadable(standardized)
        }

        let bookmark: Data
        do {
            bookmark = try bookmarkDataProvider(standardized)
        } catch {
            throw PaperNoteAssociationError.bookmarkCreationFailed(standardized)
        }
        return (version.contentHash, bookmark)
    }

    private func validateAndBookmarkMarkdown(at markdownURL: URL) throws -> Data {
        let standardized = markdownURL.standardizedFileURL
        let lease = SecurityScopeLease(url: standardized, access: access)
        defer { lease.release() }

        guard let status = try? io.status(of: standardized),
              status.exists,
              status.isRegularFile,
              !status.isCloudPlaceholder else {
            throw PaperNoteAssociationError.noteFileMissingOrUnreadable(standardized)
        }

        let data: Data
        do {
            data = try io.readContents(of: standardized)
        } catch {
            throw PaperNoteAssociationError.noteFileMissingOrUnreadable(standardized)
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw PaperNoteAssociationError.invalidMarkdownUTF8(standardized)
        }

        do {
            return try bookmarkDataProvider(standardized)
        } catch {
            throw PaperNoteAssociationError.bookmarkCreationFailed(standardized)
        }
    }

    private func findPDFCandidateResolution(
        forHash expectedHash: String,
        lastKnownURL: URL,
        in directories: [URL]
    ) -> PDFResourceResolution {
        guard !directories.isEmpty else {
            return .missing(lastKnownURL: lastKnownURL)
        }

        var matches: [URL] = []
        var seenCanonical = Set<String>()

        for dir in directories where dir.isFileURL {
            let dirLease = SecurityScopeLease(url: dir, access: access)
            defer { dirLease.release() }

            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for entry in entries where entry.pathExtension.lowercased() == "pdf" {
                let canonical = entry.resolvingSymlinksInPath().standardizedFileURL
                guard seenCanonical.insert(canonical.path).inserted else { continue }
                guard let status = try? io.status(of: canonical),
                      status.exists,
                      status.isRegularFile,
                      !status.isCloudPlaceholder,
                      let version = try? io.version(of: canonical),
                      version.contentHash == expectedHash else {
                    continue
                }
                matches.append(canonical)
            }
        }

        switch matches.count {
        case 0:
            return .missing(lastKnownURL: lastKnownURL)
        case 1:
            return .singleCandidate(matches[0])
        default:
            return .ambiguousCandidates(matches)
        }
    }

    private func isInsideConfiguredNotebookDirectory(_ fileURL: URL) -> Bool {
        guard case let .resolved(notebookURL, _) = resolveNotebookDirectory() else {
            return false
        }
        let targetDir = fileURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let notebookPath = notebookURL.resolvingSymlinksInPath().standardizedFileURL.path
        if targetDir == notebookPath { return true }
        let prefix = notebookPath.hasSuffix("/") ? notebookPath : notebookPath + "/"
        return targetDir.hasPrefix(prefix)
    }

    private func activeNotebookLeaseIfCovering(_ fileURL: URL) -> SecurityScopeLease? {
        guard case let .resolved(notebookURL, _) = resolveNotebookDirectory() else {
            return nil
        }
        let targetDir = fileURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let notebookPath = notebookURL.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = notebookPath.hasSuffix("/") ? notebookPath : notebookPath + "/"
        guard targetDir == notebookPath || targetDir.hasPrefix(prefix) else {
            return nil
        }
        return SecurityScopeLease(url: notebookURL, access: access)
    }

    private func upserting(
        _ association: PaperNoteAssociation,
        into list: [PaperNoteAssociation]
    ) -> [PaperNoteAssociation] {
        var copy = list
        if let index = copy.firstIndex(where: { $0.id == association.id }) {
            copy[index] = association
        } else {
            copy.append(association)
        }
        return copy
    }

    // MARK: - Persistence

    private func loadAssociations() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(StoredAssociations.self, from: data)
            guard decoded.version == Self.storageVersion else {
                hasUnreadableAssociationsStorage = true
                return
            }
            associations = decoded.associations
        } catch {
            hasUnreadableAssociationsStorage = true
        }
    }

    private func persistAssociations(_ candidate: [PaperNoteAssociation]) throws {
        guard !hasUnreadableAssociationsStorage else {
            throw PaperNoteAssociationError.storageCorrupted
        }
        let directory = storageURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let payload = StoredAssociations(version: Self.storageVersion, associations: candidate)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(payload)
            try associationsDataWriter(data, storageURL)
        } catch {
            throw PaperNoteAssociationError.storageWriteFailed(error.localizedDescription)
        }
    }

    private func loadNotebookDirectory() {
        guard let raw = defaults.object(forKey: Self.notebookDefaultsKey) else { return }
        guard let data = raw as? Data else {
            hasUnreadableNotebookSetting = true
            return
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(StoredNotebookDirectory.self, from: data)
            guard decoded.version == Self.notebookStorageVersion else {
                hasUnreadableNotebookSetting = true
                return
            }
            notebookDirectory = decoded.directory
        } catch {
            hasUnreadableNotebookSetting = true
        }
    }

    private func persistNotebookDirectory() {
        guard !hasUnreadableNotebookSetting, let notebookDirectory else { return }
        let payload = StoredNotebookDirectory(
            version: Self.notebookStorageVersion,
            directory: notebookDirectory
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }
        defaults.set(data, forKey: Self.notebookDefaultsKey)
    }
}
