import AppKit
import PDFKit

/// Why a note operation was refused.
///
/// Kept separate from `HighlightService.Failure` because these are the outcomes
/// a note composer has to explain while it stays open: the draft may belong to
/// a document that has since been replaced, the body may be blank, or another
/// application may have locked the annotation in the meantime.
public enum NoteEditError: Error, Equatable {
    case noDocument
    /// The body was empty or only whitespace. A note without text is not a note.
    case emptyContents
    /// The anchor was captured in a document that is no longer on screen.
    case documentChanged
    case pageUnavailable
    /// The annotation is no longer attached to the page it was read from.
    case annotationUnavailable
    /// ReadOnly, Locked, LockedContents or a document that forbids commenting.
    case permissionDenied
}

/// Note creation, editing and deletion through the reader model.
///
/// Every mutation goes through the same `MarkupEdit` pipeline as Highlight and
/// Underline: one edit, one Undo entry, one bump of the dirty state. The note
/// body is always the standard `/Contents` entry, so a note written here is
/// readable by any PDF application — the paper colour and the quoted excerpt
/// live in optional custom keys that can be lost without losing the text.
extension PDFDocumentModel {

    // MARK: - Availability

    /// Whether the document accepts new annotations at all.
    ///
    /// `/F` flags do not apply to an annotation that does not exist yet, so this
    /// is the document-level half of the permission check.
    public var canCreateNote: Bool {
        document?.allowsCommenting == true
    }

    /// Whether the toolbar's Add Note would capture a text selection.
    public var canAddSelectionNote: Bool {
        guard canCreateNote, let selection = currentSelection else { return false }
        return !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Drafts

    /// Captures the anchor for a note about the selected text.
    ///
    /// The anchor is fixed here, when the composer opens, not when Save is
    /// pressed. That is what keeps a cross-page selection on an explicit page
    /// and stops a later click or selection from moving the note.
    public func selectionNoteDraft() -> NoteDraft? {
        guard let document, canAddSelectionNote, let selection = currentSelection else {
            return nil
        }
        return NoteService.draft(from: selection, in: document)
    }

    /// Captures the anchor for a page note at a click point.
    ///
    /// Deliberately does not consult `currentSelection`: a page note created
    /// while text is still selected must not inherit that selection, neither its
    /// text nor its page.
    public func pageNoteDraft(at point: CGPoint, on page: PDFPage) -> NoteDraft? {
        guard let document, document.allowsCommenting else { return nil }
        return NoteService.draft(at: point, on: page, in: document)
    }

    // MARK: - Reading

    /// The note marker under `point`, if any.
    ///
    /// Notes are tested before markup because a marker is small and sits on top
    /// of the page; a click inside one is a request to open that note.
    public func noteSelection(at point: CGPoint, on page: PDFPage) -> NoteSelection? {
        guard let document, page.document === document else { return nil }
        let pageIndex = document.index(for: page)
        guard pageIndex >= 0 else { return nil }

        // Sticker overlays represent one YoPDF note or one ShuaMac thought
        // group. Resolve the marker before PDFKit's underlying annotation rects
        // so a grouped sticker opens its representative note at the shared hit
        // target instead of the last stacked `/Text` icon.
        if let marker = noteMarkers.reversed().first(where: {
            $0.pageIndex == pageIndex
                && ($0.bounds.insetBy(dx: -3, dy: -3).contains(point)
                    || $0.sourceHitBounds.contains { $0.contains(point) })
        }) {
            return NoteService.selection(
                for: marker.annotation,
                on: page,
                pageIndex: pageIndex,
                marker: marker
            )
        }

        // Last annotation wins, matching PDFKit's paint order.
        for annotation in page.annotations.reversed() where NoteService.isTextAnnotation(annotation) {
            guard annotation.shouldDisplay,
                  !NoteService.usesStickerPresentation(annotation),
                  NoteService.hitRect(for: annotation, on: page).contains(point)
            else { continue }
            return NoteService.selection(for: annotation, on: page, pageIndex: pageIndex)
        }
        return nil
    }

    /// Whether a captured anchor still describes the document on screen.
    ///
    /// A composer can outlive the document its anchor was taken from, and a
    /// draft committed into a different document would land on a page the user
    /// never pointed at.
    public func isCurrent(_ draft: NoteDraft) -> Bool {
        guard let document else { return false }
        return draft.documentIdentifier == ObjectIdentifier(document)
    }

    /// Whether `note` is still attached to the page it was read from.
    ///
    /// Re-checked before every write: an Undo, a delete from the context menu or
    /// a document reload can detach the annotation while the composer is open.
    public func isAttached(_ note: NoteSelection) -> Bool {
        guard let document,
              let page = document.page(at: note.pageIndex),
              page.document === document,
              note.annotation.page === page,
              page.annotations.contains(where: { $0 === note.annotation })
        else { return false }
        return true
    }

    /// The permissions the composer should offer for `note` right now.
    public func notePermissions(for note: NoteSelection) -> NotePermissions {
        guard let document,
              let page = document.page(at: note.pageIndex),
              page.document === document,
              note.annotation.page === page,
              page.annotations.contains(where: { $0 === note.annotation })
        else { return .none }
        return NoteService.permissions(for: note.annotation, in: document)
    }

    // MARK: - Creating

    /// Adds a standard `/Text` annotation for a captured anchor.
    ///
    /// The draft is revalidated against the current document before anything is
    /// written: a composer that stayed open while another file was opened must
    /// not drop its note on a page of the new document.
    @discardableResult
    public func addNote(
        _ draft: NoteDraft,
        contents: String,
        style: NoteStickerStyle
    ) -> Result<NoteSelection, NoteEditError> {
        guard let document else { return .failure(.noDocument) }
        guard isCurrent(draft) else { return .failure(.documentChanged) }
        guard document.allowsCommenting else { return .failure(.permissionDenied) }

        let text = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.emptyContents) }

        guard let page = document.page(at: draft.pageIndex),
              page.document === document
        else { return .failure(.pageUnavailable) }
        guard let annotation = NoteService.annotation(
            for: draft,
            contents: text,
            style: style,
            on: page
        ) else { return .failure(.emptyContents) }

        let edit = MarkupEdit(changes: [
            .insert(annotation: annotation, pageIndex: draft.pageIndex)
        ])
        guard performMarkupEdit(edit) else { return .failure(.permissionDenied) }

        selectedMarkup = nil
        // The text was captured into the draft, so the live selection is no
        // longer needed and must not become the anchor of the next note.
        updateSelection(nil)

        guard let selection = NoteService.selection(
            for: annotation,
            on: page,
            pageIndex: draft.pageIndex
        ) else { return .failure(.annotationUnavailable) }
        return .success(selection)
    }

    /// Compatibility entry point for callers that only choose a paper tint.
    ///
    /// New UI code uses `addNote(_:contents:style:)`; this keeps the PR #6 API
    /// working for tests and any future caller without inventing a second
    /// persistence path.
    @discardableResult
    public func addNote(
        _ draft: NoteDraft,
        contents: String,
        paperColor: NotePaperColor
    ) -> Result<NoteSelection, NoteEditError> {
        addNote(
            draft,
            contents: contents,
            style: NoteStickerStyle(motif: .plain, palette: paperColor)
        )
    }

    // MARK: - Editing

    /// Applies a body change and an appearance change as one undoable edit.
    ///
    /// Unchanged aspects are left out, so saving a colour-only change does not
    /// rewrite `/Contents`, and a LockedContents note can still be restyled.
    /// The style is read from the annotation, not from the possibly stale
    /// selection value, so another editor's change is not silently reverted.
    @discardableResult
    public func updateNote(
        _ note: NoteSelection,
        contents: String,
        style: NoteStickerStyle
    ) -> Result<NoteSelection, NoteEditError> {
        guard let document, isAttached(note),
              let page = document.page(at: note.pageIndex)
        else { return .failure(.annotationUnavailable) }

        guard document.allowsCommenting,
              MarkupPermissions.allowsPropertyChanges(note.annotation)
        else { return .failure(.permissionDenied) }

        let text = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.emptyContents) }

        let oldContents = note.annotation.contents
        let oldText = (oldContents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let oldStyle = NoteService.style(of: note.annotation)

        var changes: [MarkupEditChange] = []
        if oldText != text {
            // LockedContents is checked here rather than by the caller: the
            // composer's disabled state is a hint, this is the enforcement.
            guard MarkupPermissions.allowsContentsChanges(note.annotation) else {
                return .failure(.permissionDenied)
            }
            changes.append(.setContents(
                annotation: note.annotation,
                pageIndex: note.pageIndex,
                from: oldContents,
                to: text
            ))
        }
        if oldStyle != style {
            // An explicit style change is the documented adoption point for a
            // third-party note; a body-only edit leaves it native. The snapshot
            // also records the original `/C` and which keys did not exist, so
            // Undo removes the identity and restores the native presentation.
            changes.append(.setNoteStyle(
                annotation: note.annotation,
                pageIndex: note.pageIndex,
                from: NoteService.styleSnapshot(of: note.annotation),
                to: NoteService.styledSnapshot(for: style, on: note.annotation)
            ))
        }

        guard !changes.isEmpty else { return .success(note) }
        guard performMarkupEdit(MarkupEdit(changes: changes)) else {
            return .failure(.permissionDenied)
        }
        selectedMarkup = nil

        guard let selection = NoteService.selection(
            for: note.annotation,
            on: page,
            pageIndex: note.pageIndex
        ) else { return .failure(.annotationUnavailable) }
        return .success(selection)
    }

    /// Compatibility entry point that changes only the paper palette.
    ///
    /// The current motif is preserved, so calling this on a sticker note must
    /// not turn it back into Simple Paper.
    @discardableResult
    public func updateNote(
        _ note: NoteSelection,
        contents: String,
        paperColor: NotePaperColor
    ) -> Result<NoteSelection, NoteEditError> {
        let current = NoteService.style(of: note.annotation)
        return updateNote(
            note,
            contents: contents,
            style: NoteStickerStyle(motif: current.motif, palette: paperColor)
        )
    }

    // MARK: - Deleting

    /// Removes a note, including PDFKit's popup companion.
    @discardableResult
    public func deleteNote(_ note: NoteSelection) -> Bool {
        guard let document,
              let page = document.page(at: note.pageIndex),
              page.document === document,
              note.annotation.page === page,
              page.annotations.contains(where: { $0 === note.annotation }),
              document.allowsCommenting,
              MarkupPermissions.allowsPropertyChanges(note.annotation)
        else { return false }

        let edit = MarkupEdit(changes: [
            .remove(annotation: note.annotation, pageIndex: note.pageIndex)
        ])
        guard performMarkupEdit(edit) else { return false }
        selectedMarkup = nil
        return true
    }

    // MARK: - Markers

    /// Recomputes the page markers from the current document.
    ///
    /// Called after every annotation edit and after the document is replaced, so
    /// the overlay never draws a marker for an annotation that no longer exists.
    func refreshNoteMarkers() {
        guard let document else {
            noteMarkers = []
            return
        }
        noteMarkers = NoteService.markers(in: document)
    }
}

extension NoteEditError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noDocument:
            return "There is no document open."
        case .emptyContents:
            return "Write something before saving the note."
        case .documentChanged:
            return "This note belongs to a document that is no longer open."
        case .pageUnavailable:
            return "The page this note was anchored to is no longer available."
        case .annotationUnavailable:
            return "This note is no longer in the document."
        case .permissionDenied:
            return "This note is protected and cannot be changed."
        }
    }
}
