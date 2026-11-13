import Combine
import Foundation

/// Events emitted by a `MarkdownResourceSession` when its backing file or
/// in-memory source changes.
@MainActor
public enum MarkdownResourceEvent: Equatable {
    case opened(URL)
    case created(URL)
    case contentChanged(sourcePaneID: PaneID?)
    case reloaded(URL)
    case saved(URL)
    case savedAs(URL)
    case closed
}

/// Line-ending style detected in an opened Markdown file.
public enum MarkdownLineEnding: String, Equatable, Sendable, Codable {
    case lf = "\n"
    case crlf = "\r\n"
    case cr = "\r"
    case mixed

    /// Detects the line-ending convention used by `text`, or returns `nil` when
    /// `text` contains no line breaks.
    public static func detect(in text: String) -> MarkdownLineEnding? {
        var sawLF = false
        var sawCRLF = false
        var sawCR = false

        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        let end = scalars.endIndex

        while index < end {
            let scalar = scalars[index]
            if scalar == "\r" {
                let next = scalars.index(after: index)
                if next < end && scalars[next] == "\n" {
                    sawCRLF = true
                    index = scalars.index(after: next)
                    continue
                } else {
                    sawCR = true
                }
            } else if scalar == "\n" {
                sawLF = true
            }
            index = scalars.index(after: index)
        }

        let count = (sawLF ? 1 : 0) + (sawCRLF ? 1 : 0) + (sawCR ? 1 : 0)
        if count == 0 { return nil }
        if count > 1 { return .mixed }
        if sawCRLF { return .crlf }
        if sawCR { return .cr }
        return .lf
    }

    /// Normalizes line endings in `text` to `lineEnding`, unless `lineEnding` is
    /// `.mixed` (in which case `text` is returned unchanged).
    public static func applying(_ lineEnding: MarkdownLineEnding, to text: String) -> String {
        guard lineEnding != .mixed else { return text }

        let replacement = lineEnding.rawValue
        var result = String()
        result.reserveCapacity(text.utf8.count)

        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        let end = scalars.endIndex

        while index < end {
            let scalar = scalars[index]
            if scalar == "\r" {
                result.append(replacement)
                let next = scalars.index(after: index)
                if next < end && scalars[next] == "\n" {
                    index = scalars.index(after: next)
                } else {
                    index = next
                }
            } else if scalar == "\n" {
                result.append(replacement)
                index = scalars.index(after: index)
            } else {
                result.unicodeScalars.append(scalar)
                index = scalars.index(after: index)
            }
        }

        return result
    }
}

/// Errors reported when opening, creating, or reloading a Markdown resource.
public enum MarkdownLoadError: Error, Equatable, Sendable {
    case notAFileURL
    case unsupportedType(String)
    case fileMissing(URL)
    case permissionDenied(URL)
    case readOnly(URL)
    case targetExists(URL)
    case invalidUTF8(URL)
    case unreadable(String)
    case unsupportedFileSituation(UnsupportedFileSituation, URL)
    case unsavedChanges
    case committedButUnverified(URL, String)
}

extension MarkdownLoadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAFileURL:
            return "That location is not a local file."
        case let .unsupportedType(ext):
            if ext.isEmpty {
                return "Choose a Markdown (.md) file."
            }
            return "“.\(ext)” files are not supported as Markdown notes."
        case let .fileMissing(url):
            return "“\(url.lastPathComponent)” could not be found. It may have been moved or deleted."
        case let .permissionDenied(url):
            return "YoPDF does not have permission to access “\(url.lastPathComponent)”."
        case let .readOnly(url):
            return "“\(url.lastPathComponent)” is read-only."
        case let .targetExists(url):
            return "“\(url.lastPathComponent)” already exists."
        case let .invalidUTF8(url):
            return "“\(url.lastPathComponent)” is not valid UTF-8 text."
        case let .unreadable(reason):
            return reason
        case let .unsupportedFileSituation(situation, url):
            return DocumentStoreError.unsupportedFileSituation(situation, url).errorDescription
        case .unsavedChanges:
            return "Save or discard your changes before replacing this Markdown note."
        case let .committedButUnverified(url, reason):
            return "“\(url.lastPathComponent)” was created, but its state could not be confirmed: \(reason)"
        }
    }
}

/// Shared runtime authority for an open local UTF-8 Markdown file.
///
/// Owns the raw Markdown source string, dirty tracking, edit revision,
/// security-scoped `DocumentSession`, external-change conflict checks, and
/// atomic persistence through `DocumentStore`.
///
/// Multiple panes referencing the same Markdown file share a single
/// `MarkdownResourceSession` via pane leases (`acquireLease(for:)` /
/// `releaseLease(for:)`), preventing independent conflicting writers.
@MainActor
public final class MarkdownResourceSession: ObservableObject, Identifiable {

    public static let supportedFileExtensions: Set<String> = ["md", "markdown"]

    public let id: ResourceID

    // MARK: - Document Identity & Content

    @Published public private(set) var content: String = ""
    @Published public private(set) var fileURL: URL?
    @Published public private(set) var title: String = ""
    @Published public private(set) var detectedLineEnding: MarkdownLineEnding?
    @Published public private(set) var hasUnsavedChanges: Bool = false
    @Published public private(set) var editRevision: Int = 0
    @Published public private(set) var loadGeneration: Int = 0
    @Published public private(set) var lastError: MarkdownLoadError?
    @Published public private(set) var isLoaded: Bool = false
    @Published public private(set) var isReadOnlyAtOpen: Bool = false

    // MARK: - Autosave State

    @Published public internal(set) var autoSaveStatus: AutoSaveStatus = .idle
    @Published public internal(set) var autoSaveFailureRevision: Int = 0
    public internal(set) var lastAutoSaveOutcome: SaveOutcome?
    public var autoSaveDebounceNanoseconds: UInt64 = 750_000_000
    public var isAutoSaveEnabled: Bool = true

    // MARK: - File Session & Persistence

    let store: DocumentStore
    public private(set) var documentSession: DocumentSession?

    /// Authoritative disk baseline corresponding to `documentSession.version`.
    private var savedContent: String?
    private var savedUTF8: Data?

    private struct AutoSaveWorkSnapshot {
        let text: String
        let utf8: Data
        let generation: Int
        let scheduledRevision: Int
        let session: DocumentSession
    }

    var autoSaveTask: Task<Void, Never>?
    var autoSaveGeneration: Int = 0
    var autoSaveWorkTask: Task<SaveOutcome, Never>?
    var autoSaveWorkGeneration: Int?
    var autoSaveWorkCompletion: AutoSaveWorkCompletion?
    private var autoSaveWorkSnapshot: AutoSaveWorkSnapshot?
    var autoSavePauseDepth: Int = 0
    var autoSaveShouldResumeAfterPause: Bool = false

    /// Lifecycle and edit notifications for observing panes.
    public let events = PassthroughSubject<MarkdownResourceEvent, Never>()

    // MARK: - Pane Leases

    private var activeLeases: Set<PaneID> = []

    public init(
        id: ResourceID = ResourceID(),
        access: any SecurityScopeAccessing = SystemSecurityScopeAccess(),
        io: any DocumentStoreIO = SystemDocumentStoreIO()
    ) {
        self.id = id
        self.store = DocumentStore(access: access, io: io)
    }

    public var activeLeaseCount: Int { activeLeases.count }
    public var activePaneIDs: Set<PaneID> { activeLeases }

    public func acquireLease(for paneID: PaneID) {
        activeLeases.insert(paneID)
    }

    public func releaseLease(for paneID: PaneID) {
        guard activeLeases.remove(paneID) != nil else { return }
        if activeLeases.isEmpty {
            close()
        }
    }

    public func dismissError() {
        lastError = nil
    }

    // MARK: - Opening & Creating

    public static func isSupportedMarkdownFile(_ url: URL) -> Bool {
        supportedFileExtensions.contains(url.pathExtension.lowercased())
    }

    /// Opens an existing UTF-8 Markdown file using `DocumentStore`.
    @discardableResult
    public func open(url: URL, discardingUnsavedChanges: Bool = false) -> Bool {
        guard discardingUnsavedChanges || !hasUnsavedChanges else {
            lastError = .unsavedChanges
            return false
        }
        guard url.isFileURL else {
            lastError = .notAFileURL
            return false
        }
        guard Self.isSupportedMarkdownFile(url) else {
            lastError = .unsupportedType(url.pathExtension)
            return false
        }

        let reopeningCurrentFile = fileURL?.standardizedFileURL == url.standardizedFileURL
        if reopeningCurrentFile {
            pauseAutoSave()
        }
        defer {
            if reopeningCurrentFile {
                resumeAutoSave()
            }
        }

        let candidate: DocumentSession
        let rawBytes: Data
        let decoded: String
        do {
            candidate = try store.open(url)
            do {
                let rawData = try candidate.read()
                guard let utf8 = String(data: rawData, encoding: .utf8) else {
                    candidate.close()
                    lastError = .invalidUTF8(url)
                    return false
                }
                rawBytes = rawData
                decoded = utf8
            } catch {
                candidate.close()
                throw error
            }
        } catch let error as DocumentStoreError {
            lastError = Self.loadError(from: error)
            return false
        } catch let error as MarkdownLoadError {
            lastError = error
            return false
        } catch {
            lastError = .unreadable(error.localizedDescription)
            return false
        }

        cancelPendingAutoSave(cancelInFlightWork: discardingUnsavedChanges)
        _ = waitForAutoSaveWork()

        let previous = documentSession
        documentSession = candidate
        previous?.close()

        applyLoaded(
            text: decoded,
            rawData: rawBytes,
            url: url,
            isReadOnly: !candidate.isWritableAtOpen,
            event: .opened(url)
        )
        return true
    }

    /// Atomically creates a brand-new UTF-8 Markdown file at `url` and opens it.
    /// Never overwrites an existing file.
    @discardableResult
    public func create(
        at url: URL,
        initialContent: String = "",
        discardingUnsavedChanges: Bool = false
    ) -> Bool {
        guard discardingUnsavedChanges || !hasUnsavedChanges else {
            lastError = .unsavedChanges
            return false
        }
        guard url.isFileURL else {
            lastError = .notAFileURL
            return false
        }
        guard Self.isSupportedMarkdownFile(url) else {
            lastError = .unsupportedType(url.pathExtension)
            return false
        }

        let data = Data(initialContent.utf8)
        let candidate: DocumentSession
        do {
            candidate = try store.create(url, contents: data)
        } catch let error as DocumentStoreError {
            lastError = Self.loadError(from: error)
            return false
        } catch {
            lastError = .unreadable(error.localizedDescription)
            return false
        }

        cancelPendingAutoSave(cancelInFlightWork: discardingUnsavedChanges)
        _ = waitForAutoSaveWork()

        let previous = documentSession
        documentSession = candidate
        previous?.close()

        applyLoaded(
            text: initialContent,
            rawData: data,
            url: url,
            isReadOnly: false,
            event: .created(url)
        )
        return true
    }

    /// Reloads the currently opened Markdown file from disk, adopting any external changes.
    @discardableResult
    public func reload(discardingUnsavedChanges: Bool = false) -> Bool {
        guard let url = fileURL else {
            lastError = .unreadable("There is no open Markdown file to reload.")
            return false
        }
        guard discardingUnsavedChanges || !hasUnsavedChanges else {
            lastError = .unsavedChanges
            return false
        }

        pauseAutoSave()
        defer { resumeAutoSave() }

        let candidate: DocumentSession
        let rawBytes: Data
        let decoded: String
        do {
            candidate = try store.open(url)
            do {
                let rawData = try candidate.read()
                guard let utf8 = String(data: rawData, encoding: .utf8) else {
                    candidate.close()
                    lastError = .invalidUTF8(url)
                    return false
                }
                rawBytes = rawData
                decoded = utf8
            } catch {
                candidate.close()
                throw error
            }
        } catch let error as DocumentStoreError {
            lastError = Self.loadError(from: error)
            return false
        } catch {
            lastError = .unreadable(error.localizedDescription)
            return false
        }

        cancelPendingAutoSave(cancelInFlightWork: true)
        _ = waitForAutoSaveWork()

        let previous = documentSession
        documentSession = candidate
        previous?.close()

        applyLoaded(
            text: decoded,
            rawData: rawBytes,
            url: url,
            isReadOnly: !candidate.isWritableAtOpen,
            event: .reloaded(url)
        )
        return true
    }

    public func close() {
        cancelPendingAutoSave(cancelInFlightWork: true)
        _ = waitForAutoSaveWork()
        autoSavePauseDepth = 0
        autoSaveShouldResumeAfterPause = false
        documentSession?.close()
        documentSession = nil
        content = ""
        savedContent = nil
        savedUTF8 = nil
        fileURL = nil
        title = ""
        detectedLineEnding = nil
        hasUnsavedChanges = false
        isLoaded = false
        isReadOnlyAtOpen = false
        lastError = nil
        autoSaveStatus = .idle
        lastAutoSaveOutcome = nil
        editRevision &+= 1
        loadGeneration &+= 1
        activeLeases.removeAll()
        events.send(.closed)
    }

    // MARK: - Editing

    /// Updates the in-memory Markdown source content.
    ///
    /// - Parameters:
    ///   - newContent: Updated Markdown text.
    ///   - sourcePaneID: Optional pane originating the edit, forwarded in events.
    ///   - preserveLineEndings: When `true` and the opened file had a consistent
    ///     non-mixed line ending (such as `.crlf`), normalizes line breaks in
    ///     `newContent` to match the file's original line ending.
    public func updateContent(
        _ newContent: String,
        from sourcePaneID: PaneID? = nil,
        preserveLineEndings: Bool = false
    ) {
        guard isLoaded else { return }

        let effectiveContent: String
        if preserveLineEndings, let detectedLineEnding, detectedLineEnding != .mixed {
            effectiveContent = MarkdownLineEnding.applying(detectedLineEnding, to: newContent)
        } else {
            effectiveContent = newContent
        }

        guard !Self.utf8Equal(effectiveContent, content) else { return }

        content = effectiveContent
        let effectiveUTF8 = Data(effectiveContent.utf8)
        let matchesSavedBaseline = (savedUTF8 == effectiveUTF8)
        editRevision &+= 1

        if !matchesSavedBaseline {
            hasUnsavedChanges = true
            if isAutoSaveEnabled {
                scheduleAutoSave()
            }
        } else if let completion = autoSaveWorkCompletion {
            // An earlier autosave worker is associated with a previous revision.
            // If cancellation wins before its disk write starts, disk still holds
            // the saved baseline; if the write has already started, stay dirty
            // until that write finishes and we reconcile disk vs editor bytes.
            if completion.cancelBeforeWrite() {
                autoSaveWorkTask?.cancel()
                cancelPendingAutoSave(cancelInFlightWork: false)
                if documentSession?.state == .needsRefresh {
                    hasUnsavedChanges = true
                } else {
                    hasUnsavedChanges = false
                    autoSaveStatus = .idle
                }
            } else {
                hasUnsavedChanges = true
                autoSaveGeneration &+= 1
                autoSaveTask?.cancel()
                autoSaveTask = nil
            }
        } else {
            cancelPendingAutoSave(cancelInFlightWork: false)
            if documentSession?.state == .needsRefresh {
                hasUnsavedChanges = true
            } else {
                hasUnsavedChanges = false
                autoSaveStatus = .idle
            }
        }

        events.send(.contentChanged(sourcePaneID: sourcePaneID))
    }

    /// Reverts in-memory edits back to the last loaded/saved baseline without
    /// touching disk.
    public func discardUnsavedChanges() {
        guard isLoaded else { return }
        cancelPendingAutoSave(cancelInFlightWork: true)
        _ = waitForAutoSaveWork()
        content = savedContent ?? ""
        hasUnsavedChanges = (documentSession?.state == .needsRefresh)
        autoSaveStatus = .idle
        lastAutoSaveOutcome = nil
        editRevision &+= 1
        events.send(.contentChanged(sourcePaneID: nil))
    }

    // MARK: - External Change Detection & Saving

    public func checkExternalChange() throws -> ExternalChange {
        guard let session = documentSession else {
            throw DocumentStoreError.sessionClosed
        }
        return try session.checkExternalChange()
    }

    @discardableResult
    public func save() -> SaveOutcome {
        cancelPendingAutoSave(cancelInFlightWork: true)
        _ = waitForAutoSaveWork()

        guard isLoaded, let session = documentSession else {
            return .failed(.noDocument)
        }
        guard hasUnsavedChanges else {
            return .saved
        }

        let textToSave = content
        let data = Data(textToSave.utf8)

        do {
            try session.save(data)
        } catch let error as DocumentStoreError {
            return resolveSaveFailure(error, session: session, attemptedText: textToSave)
        } catch {
            return .failed(.store(.stagingFailed(error.localizedDescription)))
        }

        completeSave(savedText: textToSave, at: session.url, event: .saved(session.url))
        return .saved
    }

    /// Resolves a `DocumentSession` stuck in `.needsRefresh` after an uncertain
    /// or unverified save.
    @discardableResult
    public func refreshPendingSave() -> SaveOutcome {
        guard isLoaded, let session = documentSession else {
            return .failed(.noDocument)
        }

        let currentText = content
        do {
            let refreshedVersion = try session.refresh()
            let currentHash = Self.sha256Hex(of: Data(currentText.utf8))
            if refreshedVersion.contentHash == currentHash {
                completeSave(savedText: currentText, at: session.url, event: .saved(session.url))
                return .saved
            }
            return .failed(.store(.replacementFailed("The previous save did not land; the original file is intact.")))
        } catch let error as DocumentStoreError {
            if case .externalModificationDetected = error {
                return .conflict(error)
            }
            return .failed(.store(error))
        } catch {
            return .failed(.store(.stagingFailed(error.localizedDescription)))
        }
    }

    @discardableResult
    public func saveAs(to destination: URL, overwrite: Bool = false) -> SaveOutcome {
        cancelPendingAutoSave(cancelInFlightWork: true)
        _ = waitForAutoSaveWork()

        guard isLoaded, let session = documentSession else {
            return .failed(.noDocument)
        }
        guard destination.isFileURL else {
            return .failed(.store(.notAFileURL))
        }

        let textToSave = content
        let data = Data(textToSave.utf8)

        do {
            let newSession = try session.saveAs(data, to: destination, overwrite: overwrite)
            let previous = documentSession
            documentSession = newSession
            previous?.close()

            isReadOnlyAtOpen = !newSession.isWritableAtOpen
            completeSave(savedText: textToSave, at: newSession.url, event: .savedAs(newSession.url))
            loadGeneration &+= 1
            return .saved
        } catch let error as DocumentStoreError {
            return resolveSaveAsFailure(error, attemptedText: textToSave)
        } catch {
            return .failed(.store(.stagingFailed(error.localizedDescription)))
        }
    }

    // MARK: - Autosave Coordination

    public func withAutoSavePaused<T>(_ operation: () throws -> T) rethrows -> T {
        pauseAutoSave()
        defer { resumeAutoSave() }
        return try operation()
    }

    func pauseAutoSave() {
        autoSavePauseDepth += 1
        guard autoSavePauseDepth == 1 else { return }

        let hasScheduledSave = autoSaveStatus == .pending || autoSaveStatus == .saving
        guard hasScheduledSave else {
            autoSaveShouldResumeAfterPause = false
            return
        }

        let cancellationWon = autoSaveWorkCompletion?.cancelBeforeWrite()
        let writeAlreadyStarted = cancellationWon == false
        let currentAttemptHasStartedWriting = autoSaveStatus == .saving
            && autoSaveWorkGeneration == autoSaveGeneration
            && writeAlreadyStarted
        autoSaveShouldResumeAfterPause = hasUnsavedChanges && !currentAttemptHasStartedWriting
        guard !currentAttemptHasStartedWriting else { return }

        autoSaveGeneration &+= 1
        autoSaveTask?.cancel()
        autoSaveTask = nil
        if cancellationWon == true {
            autoSaveWorkTask?.cancel()
        }
        autoSaveStatus = .idle
    }

    func resumeAutoSave() {
        guard autoSavePauseDepth > 0 else { return }
        autoSavePauseDepth -= 1
        guard autoSavePauseDepth == 0 else { return }

        let shouldResume = autoSaveShouldResumeAfterPause
        autoSaveShouldResumeAfterPause = false
        guard shouldResume, hasUnsavedChanges, isAutoSaveEnabled else { return }
        if case .failed = autoSaveStatus { return }
        scheduleAutoSave()
    }

    func scheduleAutoSave() {
        if autoSavePauseDepth > 0 {
            autoSaveShouldResumeAfterPause = true
            autoSaveTask?.cancel()
            autoSaveTask = nil
            autoSaveGeneration &+= 1
            autoSaveStatus = .pending
            lastAutoSaveOutcome = nil
            return
        }

        autoSaveTask?.cancel()
        autoSaveGeneration &+= 1
        let generation = autoSaveGeneration
        let scheduledRevision = editRevision
        autoSaveStatus = .pending
        lastAutoSaveOutcome = nil

        autoSaveTask = Task { [weak self] in
            do {
                guard let delay = self?.autoSaveDebounceNanoseconds else { return }
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            await self?.performAutomaticSave(
                generation: generation,
                scheduledRevision: scheduledRevision
            )
        }
    }

    private func performAutomaticSave(generation: Int, scheduledRevision: Int) async {
        guard autoSaveGeneration == generation,
              editRevision == scheduledRevision,
              hasUnsavedChanges
        else { return }

        autoSaveStatus = .saving

        if let previousWork = autoSaveWorkTask {
            let previousGeneration = autoSaveWorkGeneration
            let previousSnapshot = autoSaveWorkSnapshot
            let previousOutcome = await previousWork.value
            if autoSaveWorkGeneration == previousGeneration {
                clearAutoSaveWork(ifGeneration: previousGeneration)
                if let previousSnapshot {
                    reconcileAutoSaveOutcome(
                        previousOutcome,
                        snapshot: previousSnapshot,
                        triggeredByManualInterruption: false
                    )
                }
            }
            if case .failed = autoSaveStatus {
                return
            }
        }

        guard autoSaveGeneration == generation,
              editRevision == scheduledRevision,
              hasUnsavedChanges,
              isLoaded,
              let session = documentSession,
              session.state == .open
        else { return }

        let textSnapshot = content
        let data = Data(textSnapshot.utf8)
        let completion = AutoSaveWorkCompletion()
        let snapshot = AutoSaveWorkSnapshot(
            text: textSnapshot,
            utf8: data,
            generation: generation,
            scheduledRevision: scheduledRevision,
            session: session
        )

        let worker = Task.detached(priority: .utility) {
            guard completion.beginWriteUnlessCancelled() else {
                let outcome = SaveOutcome.failed(.sessionUnavailable)
                completion.complete(with: outcome)
                return outcome
            }
            let outcome = Self.performSessionSave(data, to: session)
            completion.complete(with: outcome)
            return outcome
        }

        autoSaveWorkTask = worker
        autoSaveWorkGeneration = generation
        autoSaveWorkCompletion = completion
        autoSaveWorkSnapshot = snapshot

        let outcome = await worker.value
        guard autoSaveWorkGeneration == generation else { return }
        clearAutoSaveWork(ifGeneration: generation)
        reconcileAutoSaveOutcome(
            outcome,
            snapshot: snapshot,
            triggeredByManualInterruption: false
        )
    }

    nonisolated private static func performSessionSave(_ data: Data, to session: DocumentSession) -> SaveOutcome {
        do {
            try session.save(data)
            return .saved
        } catch let error as DocumentStoreError {
            switch error {
            case let .committedButUnverified(_, reason):
                do {
                    _ = try session.refresh()
                    return .saved
                } catch {
                    let detail = (error as? DocumentStoreError)?.localizedDescription
                        ?? error.localizedDescription
                    return .savedUnverified(reason: "\(reason) \(detail)", editsOnDisk: false)
                }
            case let .externalModificationDetected(change):
                return .conflict(.externalModificationDetected(change))
            case let .replacementStateUncertain(recovery):
                return .uncertain(
                    reason: DocumentStoreError.replacementStateUncertain(recovery).localizedDescription,
                    recovery: recovery.recoverableURLs
                )
            default:
                return .failed(.store(error))
            }
        } catch {
            return .failed(.store(.stagingFailed(error.localizedDescription)))
        }
    }

    private func clearAutoSaveWork(ifGeneration generation: Int?) {
        guard let generation, autoSaveWorkGeneration == generation else { return }
        autoSaveWorkTask = nil
        autoSaveWorkGeneration = nil
        autoSaveWorkCompletion = nil
        autoSaveWorkSnapshot = nil
    }

    private func reconcileAutoSaveOutcome(
        _ outcome: SaveOutcome,
        snapshot: AutoSaveWorkSnapshot,
        triggeredByManualInterruption: Bool
    ) {
        guard isLoaded, documentSession === snapshot.session else { return }
        if case .failed(.sessionUnavailable) = outcome {
            return
        }

        let currentUTF8 = Data(content.utf8)

        if outcome.editsAreOnDisk {
            savedContent = snapshot.text
            savedUTF8 = snapshot.utf8
            fileURL = snapshot.session.url
            title = Self.resolvedTitle(for: snapshot.session.url)
            detectedLineEnding = MarkdownLineEnding.detect(in: snapshot.text)
            isReadOnlyAtOpen = false

            let matchesEditorContent = (currentUTF8 == snapshot.utf8)
            hasUnsavedChanges = !matchesEditorContent

            if matchesEditorContent {
                lastAutoSaveOutcome = outcome
                if !triggeredByManualInterruption {
                    autoSaveStatus = .saved
                    autoSaveTask = nil
                }
                editRevision &+= 1
                events.send(.saved(snapshot.session.url))
            } else {
                // Disk now holds `snapshot.utf8`, while the editor has a newer
                // edit (or a revert back to the prior baseline). Never report clean.
                lastAutoSaveOutcome = outcome
                events.send(.saved(snapshot.session.url))
                if !triggeredByManualInterruption {
                    if isAutoSaveEnabled && autoSavePauseDepth == 0 {
                        if autoSaveTask == nil {
                            scheduleAutoSave()
                        } else {
                            autoSaveStatus = .pending
                        }
                    } else {
                        autoSaveStatus = .idle
                        autoSaveTask = nil
                    }
                }
            }
            return
        }

        // The in-flight write did not confirm bytes on disk.
        let baselineMatchesEditor = (savedUTF8 == currentUTF8)
        let sessionNeedsRefresh = (snapshot.session.state == .needsRefresh)
        let isConflict: Bool
        if case .conflict = outcome {
            isConflict = true
        } else {
            isConflict = false
        }

        if sessionNeedsRefresh || isConflict {
            hasUnsavedChanges = true
        } else {
            hasUnsavedChanges = !baselineMatchesEditor
        }

        guard !triggeredByManualInterruption else { return }

        lastAutoSaveOutcome = outcome
        if hasUnsavedChanges {
            autoSaveStatus = .failed(outcome)
            autoSaveFailureRevision &+= 1
        } else {
            autoSaveStatus = .idle
        }
        autoSaveTask = nil
    }

    @discardableResult
    func cancelPendingAutoSave(cancelInFlightWork: Bool = false) -> Bool? {
        autoSaveGeneration &+= 1
        autoSaveTask?.cancel()
        autoSaveTask = nil
        var writeWasCancelledBeforeStart: Bool?
        if cancelInFlightWork {
            writeWasCancelledBeforeStart = autoSaveWorkCompletion?.cancelBeforeWrite()
            autoSaveWorkTask?.cancel()
        }
        if autoSaveStatus == .pending || autoSaveStatus == .saving {
            autoSaveStatus = .idle
        }
        return writeWasCancelledBeforeStart
    }

    @discardableResult
    func waitForAutoSaveWork() -> SaveOutcome? {
        guard let completion = autoSaveWorkCompletion else { return nil }
        let snapshot = autoSaveWorkSnapshot
        completion.wait()
        let outcome = completion.outcome
        autoSaveWorkTask = nil
        autoSaveWorkGeneration = nil
        autoSaveWorkCompletion = nil
        autoSaveWorkSnapshot = nil
        if let outcome, let snapshot {
            reconcileAutoSaveOutcome(
                outcome,
                snapshot: snapshot,
                triggeredByManualInterruption: true
            )
        }
        return outcome
    }

    // MARK: - Private Helpers

    private func applyLoaded(
        text: String,
        rawData: Data,
        url: URL,
        isReadOnly: Bool,
        event: MarkdownResourceEvent
    ) {
        content = text
        savedContent = text
        savedUTF8 = rawData
        fileURL = url
        title = Self.resolvedTitle(for: url)
        detectedLineEnding = MarkdownLineEnding.detect(in: text)
        hasUnsavedChanges = false
        isLoaded = true
        isReadOnlyAtOpen = isReadOnly
        lastError = nil
        autoSaveStatus = .idle
        lastAutoSaveOutcome = nil
        editRevision &+= 1
        loadGeneration &+= 1
        events.send(event)
    }

    private func completeSave(
        savedText: String,
        at url: URL,
        event: MarkdownResourceEvent
    ) {
        cancelPendingAutoSave(cancelInFlightWork: false)
        let savedBytes = Data(savedText.utf8)
        savedContent = savedText
        savedUTF8 = savedBytes
        fileURL = url
        title = Self.resolvedTitle(for: url)
        detectedLineEnding = MarkdownLineEnding.detect(in: savedText)
        hasUnsavedChanges = !Self.utf8Equal(content, savedText)
        isReadOnlyAtOpen = false
        autoSaveStatus = .idle
        lastAutoSaveOutcome = nil
        editRevision &+= 1
        events.send(event)
    }

    private static func utf8Equal(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    private func resolveSaveFailure(
        _ error: DocumentStoreError,
        session: DocumentSession,
        attemptedText: String
    ) -> SaveOutcome {
        switch error {
        case let .committedButUnverified(_, reason):
            do {
                _ = try session.refresh()
                completeSave(savedText: attemptedText, at: session.url, event: .saved(session.url))
                return .saved
            } catch {
                let detail = (error as? DocumentStoreError)?.localizedDescription
                    ?? error.localizedDescription
                return .savedUnverified(reason: "\(reason) \(detail)", editsOnDisk: false)
            }
        case let .externalModificationDetected(change):
            return .conflict(.externalModificationDetected(change))
        case let .replacementStateUncertain(recovery):
            return .uncertain(
                reason: DocumentStoreError.replacementStateUncertain(recovery).localizedDescription,
                recovery: recovery.recoverableURLs
            )
        default:
            return .failed(.store(error))
        }
    }

    private func resolveSaveAsFailure(
        _ error: DocumentStoreError,
        attemptedText: String
    ) -> SaveOutcome {
        switch error {
        case let .committedButUnverified(url, reason):
            if let reopened = try? store.open(url) {
                let previous = documentSession
                documentSession = reopened
                previous?.close()
                isReadOnlyAtOpen = !reopened.isWritableAtOpen
                completeSave(savedText: attemptedText, at: reopened.url, event: .savedAs(reopened.url))
                loadGeneration &+= 1
                return .saved
            }
            return .savedUnverified(
                reason: "“\(url.lastPathComponent)” was written, but it could not be reopened, "
                    + "so this session is still tracking the original file. \(reason)",
                editsOnDisk: true
            )
        case let .externalModificationDetected(change):
            return .conflict(.externalModificationDetected(change))
        case let .replacementStateUncertain(recovery):
            return .uncertain(
                reason: DocumentStoreError.replacementStateUncertain(recovery).localizedDescription,
                recovery: recovery.recoverableURLs
            )
        default:
            return .failed(.store(error))
        }
    }

    private static func resolvedTitle(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? "Untitled" : name
    }

    static func loadError(from error: DocumentStoreError) -> MarkdownLoadError {
        switch error {
        case .notAFileURL:
            return .notAFileURL
        case .fileMissing:
            return .fileMissing(error.associatedURL ?? URL(fileURLWithPath: "/"))
        case let .permissionDenied(url):
            return .permissionDenied(url)
        case let .readOnly(url):
            return .readOnly(url)
        case let .targetExists(url):
            return .targetExists(url)
        case let .unsupportedFileSituation(situation, url):
            return .unsupportedFileSituation(situation, url)
        case let .committedButUnverified(url, reason):
            return .committedButUnverified(url, reason)
        case .notReadable, .sessionClosed, .externalModificationDetected,
             .stagingFailed, .replacementFailed, .replacementStateUncertain,
             .sessionNeedsRefresh, .reloadRequired, .coordinationFailed,
             .targetAppearedDuringSave:
            return .unreadable(error.localizedDescription)
        }
    }

    private static func sha256Hex(of data: Data) -> String {
        SystemDocumentStoreIO.sha256Hex(of: data)
    }
}

/// Window/workspace-scoped pool of active `MarkdownResourceSession` instances.
///
/// Ensures multiple panes opening the same Markdown file (by canonical path or
/// physical file identity) share one runtime session and one `DocumentSession`
/// writer rather than creating independent conflicting writers.
@MainActor
public final class MarkdownResourcePool: ObservableObject {

    @Published public private(set) var activeSessions: [MarkdownResourceSession] = []

    private let access: any SecurityScopeAccessing
    private let io: any DocumentStoreIO
    private var eventCancellables: [ResourceID: AnyCancellable] = [:]

    public init(
        access: any SecurityScopeAccessing = SystemSecurityScopeAccess(),
        io: any DocumentStoreIO = SystemDocumentStoreIO()
    ) {
        self.access = access
        self.io = io
    }

    public func session(for id: ResourceID) -> MarkdownResourceSession? {
        activeSessions.first { $0.id == id && $0.isLoaded }
    }

    public func session(for url: URL) -> MarkdownResourceSession? {
        guard url.isFileURL else { return nil }
        let targetCanonical = url.resolvingSymlinksInPath().standardizedFileURL
        if let pathMatch = activeSessions.first(where: { session in
            guard session.isLoaded, let existingURL = session.fileURL else { return false }
            return existingURL.resolvingSymlinksInPath().standardizedFileURL == targetCanonical
        }) {
            return pathMatch
        }

        if let targetVersion = try? io.version(of: url) {
            return activeSessions.first { session in
                guard session.isLoaded,
                      let existingIdentity = session.documentSession?.version.identity else { return false }
                return existingIdentity == targetVersion.identity
            }
        }
        return nil
    }

    public func open(url: URL, for paneID: PaneID) -> Result<MarkdownResourceSession, MarkdownLoadError> {
        guard url.isFileURL else { return .failure(.notAFileURL) }
        guard MarkdownResourceSession.isSupportedMarkdownFile(url) else {
            return .failure(.unsupportedType(url.pathExtension))
        }

        if let existing = session(for: url) {
            existing.acquireLease(for: paneID)
            return .success(existing)
        }

        let created = MarkdownResourceSession(access: access, io: io)
        guard created.open(url: url) else {
            return .failure(created.lastError ?? .unreadable("Could not open “\(url.lastPathComponent)”."))
        }
        register(created, for: paneID)
        return .success(created)
    }

    public func create(
        at url: URL,
        initialContent: String = "",
        for paneID: PaneID
    ) -> Result<MarkdownResourceSession, MarkdownLoadError> {
        guard url.isFileURL else { return .failure(.notAFileURL) }
        guard MarkdownResourceSession.isSupportedMarkdownFile(url) else {
            return .failure(.unsupportedType(url.pathExtension))
        }

        if session(for: url) != nil {
            return .failure(.targetExists(url))
        }

        let created = MarkdownResourceSession(access: access, io: io)
        guard created.create(at: url, initialContent: initialContent) else {
            return .failure(created.lastError ?? .unreadable("Could not create “\(url.lastPathComponent)”."))
        }
        register(created, for: paneID)
        return .success(created)
    }

    public func register(_ session: MarkdownResourceSession, for paneID: PaneID) {
        session.acquireLease(for: paneID)
        if !activeSessions.contains(where: { $0.id == session.id }) {
            activeSessions.append(session)
            let sessionID = session.id
            eventCancellables[sessionID] = session.events.sink { [weak self, weak session] event in
                guard let self else { return }
                if case .closed = event {
                    self.activeSessions.removeAll { $0.id == sessionID || $0 === session }
                    self.eventCancellables.removeValue(forKey: sessionID)
                }
            }
        }
    }

    public func release(session: MarkdownResourceSession, for paneID: PaneID) {
        session.releaseLease(for: paneID)
        if !session.isLoaded {
            activeSessions.removeAll { $0.id == session.id }
            eventCancellables.removeValue(forKey: session.id)
        }
    }
}

private extension DocumentStoreError {
    var associatedURL: URL? {
        switch self {
        case let .fileMissing(url),
             let .permissionDenied(url),
             let .readOnly(url),
             let .notReadable(url, _),
             let .targetExists(url),
             let .unsupportedFileSituation(_, url),
             let .committedButUnverified(url, _),
             let .targetAppearedDuringSave(url):
            return url
        default:
            return nil
        }
    }
}
