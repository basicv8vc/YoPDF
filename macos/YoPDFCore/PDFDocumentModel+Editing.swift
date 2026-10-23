import Foundation
import PDFKit

/// A save that never reached the file store.
///
/// Kept apart from `DocumentStoreError` because these happen before the store is
/// involved at all: there is no file-level outcome to report, and no bytes were
/// staged.
public enum SaveError: Error, Equatable {
    case noDocument
    /// PDFKit could not serialise the document. Nothing was written.
    case serializationFailed
    case sessionUnavailable
    case store(DocumentStoreError)
}

/// The result of a save attempt, in the terms the reader needs.
///
/// The distinction that matters is not "success / failure" but **whether the
/// bytes reached the file**: a save that wrote the file and then failed to
/// re-sync the in-memory document is a different situation from a save that
/// wrote nothing, and telling the user "your work was not saved" in the first
/// case would be a lie that invites a destructive retry.
public enum SaveOutcome: Equatable {
    /// The file was written and the in-memory document now matches it.
    case saved
    /// The file was written, but the app could not confirm or re-sync it.
    /// `editsOnDisk` says whether the edits may be treated as stored.
    case savedUnverified(reason: String, editsOnDisk: Bool)
    /// Nothing was written: the file changed underneath, and the edits are
    /// still only in memory.
    case conflict(DocumentStoreError)
    /// The replacement ended in a state that could not be classified. Every
    /// surviving copy is listed; nothing was deleted.
    case uncertain(reason: String, recovery: [URL])
    /// Nothing was written.
    case failed(SaveError)

    /// Whether the current edits are known to be on disk.
    public var editsAreOnDisk: Bool {
        switch self {
        case .saved:
            return true
        case let .savedUnverified(_, editsOnDisk):
            return editsOnDisk
        case .conflict, .uncertain, .failed:
            return false
        }
    }
}

extension PDFDocumentModel {

    // MARK: - Highlight

    /// Whether the Highlight command would produce a real annotation.
    ///
    /// Drives the button and the menu item, so both agree with what
    /// `HighlightService` will accept.
    public var canAddHighlight: Bool {
        canAddMarkup(.highlight)
    }

    /// Highlights the current selection, if it holds text.
    ///
    /// Returns what was added, or `nil` when there was nothing to highlight —
    /// in which case the document is left exactly as it was.
    @discardableResult
    public func addHighlightToSelection() -> HighlightService.Summary? {
        addMarkup(.highlight)
    }

    /// Underlines the current selection, using the Underline default colour.
    @discardableResult
    public func addUnderlineToSelection() -> HighlightService.Summary? {
        addMarkup(.underline)
    }

    // MARK: - Saving

    /// Writes the in-memory document back through its session.
    ///
    /// The document is serialised with PDFKit and handed to `DocumentSession`,
    /// which owns the version check, the staging file and the coordinated
    /// replacement. Nothing here writes to the original path directly: doing so
    /// would bypass the external-change check that makes a save safe.
    ///
    /// After a successful write the document is re-opened from the file. That is
    /// not cosmetic: the replacement gives the file a new inode, so the
    /// `PDFDocument` that was memory-mapping the old one no longer describes the
    /// file the session now owns. Re-opening is also the only end-to-end check
    /// that what was written is a readable PDF.
    @discardableResult
    public func save() -> SaveOutcome {
        guard let document, let session = documentSession else { return .failed(.noDocument) }
        guard hasUnsavedChanges else { return .saved }
        guard let data = NoteService.dataRepresentationPreservingShuaGroups(in: document) else {
            return .failed(.serializationFailed)
        }

        do {
            try session.save(data)
        } catch let error as DocumentStoreError {
            return resolveSaveFailure(error, session: session)
        } catch {
            return .failed(.store(.stagingFailed(error.localizedDescription)))
        }
        return finishWrite()
    }

    /// Writes the document to another file and continues editing there.
    ///
    /// The escape hatch for a read-only file, a hard link, or a conflict the
    /// user does not want to resolve in place.
    @discardableResult
    public func saveAs(to destination: URL, overwrite: Bool = false) -> SaveOutcome {
        guard let document, let session = documentSession else { return .failed(.noDocument) }
        guard let data = NoteService.dataRepresentationPreservingShuaGroups(in: document) else {
            return .failed(.serializationFailed)
        }

        do {
            let newSession = try session.saveAs(data, to: destination, overwrite: overwrite)
            // Read the new file before the old session is closed: closing it
            // releases the access the still-displayed document was opened
            // under, and there is no reason to make the reader depend on how
            // long PDFKit keeps its own descriptor open.
            let reloaded = reloadedDocument(at: destination)
            adoptFileLocation(destination)
            adoptSession(newSession)
            markSaved()
            guard let reloaded else {
                return .savedUnverified(
                    reason: "The copy was written, but it could not be reopened.",
                    editsOnDisk: true
                )
            }
            swapDocument(reloaded, at: readingPosition)
            return .saved
        } catch let error as DocumentStoreError {
            return resolveSaveAsFailure(error)
        } catch {
            return .failed(.store(.stagingFailed(error.localizedDescription)))
        }
    }

    /// Forgets the edits without writing anything.
    ///
    /// Only correct when the document is about to be closed or replaced: the
    /// in-memory annotations are still there, so the model must not keep
    /// claiming they are unsaved after the user chose to discard them.
    public func abandonUnsavedChanges() {
        markSaved()
    }

    // MARK: - Outcomes

    private func finishWrite() -> SaveOutcome {
        markSaved()
        if let reason = resyncDocumentAfterWrite() {
            return .savedUnverified(reason: reason, editsOnDisk: true)
        }
        return .saved
    }

    private func resolveSaveFailure(
        _ error: DocumentStoreError,
        session: DocumentSession
    ) -> SaveOutcome {
        switch error {
        case let .committedButUnverified(_, reason):
            // The bytes are on disk; the session just could not read the new
            // version back. `refresh()` is the only operation that can turn
            // "probably written" into a known state, so try it before
            // reporting anything to the user.
            do {
                _ = try session.refresh()
                return finishWrite()
            } catch {
                let detail = (error as? DocumentStoreError)?.localizedDescription
                    ?? error.localizedDescription
                // Undecided: keep the edits marked unsaved so nothing treats
                // them as safely stored.
                return .savedUnverified(reason: "\(reason) \(detail)", editsOnDisk: false)
            }
        case let .externalModificationDetected(change):
            return .conflict(.externalModificationDetected(change))
        case let .replacementStateUncertain(recovery):
            return uncertainOutcome(recovery)
        default:
            return .failed(.store(error))
        }
    }

    /// Save As, in the same three-way split as a save: committed, not
    /// committed, or undecided.
    ///
    /// The distinction matters more here than for a save in place, because the
    /// original file is untouched either way — what is at stake is whether the
    /// *copy* exists and whether this window still owns unsaved edits.
    private func resolveSaveAsFailure(_ error: DocumentStoreError) -> SaveOutcome {
        switch error {
        case let .committedButUnverified(url, reason):
            // The copy was written; only taking ownership of it failed. Opening
            // a session here is what keeps the window pointed at a real file
            // instead of leaving it on the original while claiming nothing
            // happened.
            if let reopened = try? store.open(url) {
                adoptSession(reopened)
                adoptFileLocation(url)
                return finishWrite()
            }
            // Still committed, and still not adoptable. Reporting this as a
            // plain failure would invite the user to save again on top of a
            // copy that already exists, so it is reported as what it is: the
            // bytes are on disk, the window could not switch to them, and the
            // edits stay marked unsaved because this window is still showing
            // the original file.
            return .savedUnverified(
                reason: "“\(url.lastPathComponent)” was written, but it could not be opened, "
                    + "so this window is still showing the original file. \(reason)",
                editsOnDisk: true
            )
        case let .externalModificationDetected(change):
            // The destination changed between the panel and the commit. The
            // copy was not written; the edits are still only in memory.
            return .conflict(.externalModificationDetected(change))
        case let .replacementStateUncertain(recovery):
            // The destination may hold the copy, the original of the
            // destination, or neither. Nothing was deleted.
            return uncertainOutcome(recovery)
        default:
            return .failed(.store(error))
        }
    }

    /// A replacement that ended in a state the store could not classify.
    ///
    /// Every surviving file is listed and the edits stay unsaved: the outcome is
    /// "unknown", which is not the same as "failed" and must not be presented as
    /// one.
    private func uncertainOutcome(_ recovery: ReplacementRecovery) -> SaveOutcome {
        .uncertain(
            reason: DocumentStoreError.replacementStateUncertain(recovery).localizedDescription,
            recovery: recovery.recoverableURLs
        )
    }

    /// Re-opens the file the session now owns and swaps it in, keeping the
    /// reading position.
    ///
    /// Returns a reason when the swap could not happen. That is **not** a failed
    /// save: the bytes are already committed, and the caller reports it as
    /// "saved, but the view could not be re-synced" instead.
    private func resyncDocumentAfterWrite() -> String? {
        guard let url = fileURL else { return "The document has no file location." }
        guard let reloaded = reloadedDocument(at: url) else {
            return "The file was written, but it could not be reopened."
        }
        swapDocument(reloaded, at: readingPosition)
        return nil
    }

    /// Re-opens `url` and checks that it still describes the same document.
    ///
    /// Refusing a reload that lost pages is deliberate: the file is written
    /// either way, but the reader should keep showing something coherent until
    /// the user reopens it.
    private func reloadedDocument(at url: URL) -> PDFDocument? {
        guard let reloaded = PDFDocument(url: url), reloaded.pageCount > 0 else { return nil }
        guard let current = document, reloaded.pageCount == current.pageCount else { return nil }
        return reloaded
    }
}

extension SaveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noDocument:
            return "There is no document to save."
        case .serializationFailed:
            return "The document could not be prepared for saving. The file was not changed."
        case .sessionUnavailable:
            return "The document is no longer open."
        case let .store(error):
            return error.errorDescription
        }
    }
}
