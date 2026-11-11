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
    /// Shua's persisted identity fields disagree or cannot be parsed. Appending
    /// would risk overwriting the original group identity, so the operation is refused.
    case conflictingIdentity
    /// ReadOnly, Locked, LockedContents or a document that forbids commenting.
    case permissionDenied
}

/// Note creation, editing and deletion through the reader resource session.
///
/// Every mutation goes through the same `MarkupEdit` pipeline as Highlight and
/// Underline: one edit, one Undo entry, one bump of the dirty state. The note
/// body is always the standard `/Contents` entry, so a note written here is
/// readable by any PDF application — the paper colour and the quoted excerpt
/// live in optional custom keys that can be lost without losing the text.
extension PDFResourceSession {

    // MARK: - Availability

    /// Whether the document accepts new annotations at all.
    public var canCreateNote: Bool {
        document?.allowsCommenting == true
    }

    // MARK: - Drafts

    /// Captures the anchor for a note about the selected text.
    public func selectionNoteDraft(from selection: PDFSelection?) -> NoteDraft? {
        guard let document, canCreateNote, let selection,
              !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return NoteService.draft(from: selection, in: document)
    }

    /// Captures the anchor for a page note at a click point.
    public func pageNoteDraft(at point: CGPoint, on page: PDFPage) -> NoteDraft? {
        guard let document, document.allowsCommenting else { return nil }
        return NoteService.draft(at: point, on: page, in: document)
    }

    // MARK: - Reading

    /// The note marker under `point`, if any.
    public func noteSelection(at point: CGPoint, on page: PDFPage) -> NoteSelection? {
        guard let document, page.document === document else { return nil }
        let pageIndex = document.index(for: page)
        guard pageIndex >= 0 else { return nil }

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

        for annotation in page.annotations.reversed() where NoteService.isTextAnnotation(annotation) {
            guard annotation.shouldDisplay,
                  !NoteService.usesStickerPresentation(annotation),
                  NoteService.hitRect(for: annotation, on: page).contains(point)
            else { continue }
            return NoteService.selection(for: annotation, on: page, pageIndex: pageIndex)
        }
        return nil
    }

    /// Resolves one saved thought into a normal single-note selection for the
    /// row's Edit and Delete actions in the group composer.
    public func noteSelection(
        forThreadEntry entry: NoteThreadEntry,
        in group: NoteSelection
    ) -> NoteSelection? {
        guard isAttached(group),
              let page = document?.page(at: group.pageIndex),
              entry.annotation.page === page,
              page.annotations.contains(where: { $0 === entry.annotation })
        else { return nil }
        return NoteService.selection(
            for: entry.annotation,
            on: page,
            pageIndex: group.pageIndex
        )
    }

    /// Whether a captured anchor still describes the document on screen.
    public func isCurrent(_ draft: NoteDraft) -> Bool {
        guard let document else { return false }
        return draft.documentIdentifier == ObjectIdentifier(document)
    }

    /// Whether `note` is still attached to the page it was read from.
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

    /// Moves a sticker marker and its PDF note rectangle as one undoable edit.
    @discardableResult
    public func moveNoteMarker(_ note: NoteSelection, to proposedCenter: CGPoint) -> Bool {
        guard let document,
              isAttached(note),
              note.usesStickerPresentation,
              proposedCenter.x.isFinite,
              proposedCenter.y.isFinite,
              document.allowsCommenting,
              let page = document.page(at: note.pageIndex),
              let marker = noteMarkers.first(where: {
                  $0.pageIndex == note.pageIndex && $0.id == note.id
              })
        else { return false }

        let annotations: [PDFAnnotation]
        if NoteService.isShuaThought(note.annotation) {
            if let groupID = NoteService.shuaAnchorID(of: note.annotation) {
                annotations = page.annotations.filter {
                    NoteService.shuaAnchorID(of: $0) == groupID
                }
            } else {
                annotations = NoteService.shuaStackMembers(of: note.annotation, on: page)
            }
        } else {
            annotations = marker.threadEntries.map(\.annotation)
        }
        guard !annotations.isEmpty,
              annotations.contains(where: { $0 === note.annotation }),
              annotations.allSatisfy({ annotation in
                  annotation.page === page
                      && page.annotations.contains(where: { $0 === annotation })
                      && MarkupPermissions.allowsAnnotationChanges(annotation, in: document)
              })
        else { return false }

        let crop = page.bounds(for: .cropBox)
        let movingBounds = annotations.reduce(marker.bounds) { $0.union($1.bounds) }
        guard crop.width.isFinite, crop.height.isFinite,
              crop.width > 0, crop.height > 0,
              movingBounds.minX.isFinite, movingBounds.minY.isFinite,
              movingBounds.maxX.isFinite, movingBounds.maxY.isFinite,
              movingBounds.width <= crop.width, movingBounds.height <= crop.height
        else { return false }

        let requestedStickerBounds = NoteService.displayBounds(
            center: proposedCenter,
            in: crop,
            count: marker.count,
            showsCountBadge: marker.showsCountBadge
        )
        let currentCenter = CGPoint(x: marker.bounds.midX, y: marker.bounds.midY)
        let requestedDelta = CGPoint(
            x: requestedStickerBounds.midX - currentCenter.x,
            y: requestedStickerBounds.midY - currentCenter.y
        )
        let minimumDelta = CGPoint(
            x: crop.minX - movingBounds.minX,
            y: crop.minY - movingBounds.minY
        )
        let maximumDelta = CGPoint(
            x: crop.maxX - movingBounds.maxX,
            y: crop.maxY - movingBounds.maxY
        )
        guard minimumDelta.x <= maximumDelta.x,
              minimumDelta.y <= maximumDelta.y
        else { return false }

        let delta = CGPoint(
            x: min(max(requestedDelta.x, minimumDelta.x), maximumDelta.x),
            y: min(max(requestedDelta.y, minimumDelta.y), maximumDelta.y)
        )
        guard hypot(delta.x, delta.y) > 0.25 else { return false }
        let targetCenter = CGPoint(
            x: currentCenter.x + delta.x,
            y: currentCenter.y + delta.y
        )

        let changes = annotations.compactMap { annotation -> MarkupEditChange? in
            let from = NoteService.positionSnapshot(of: annotation)
            let translatedBounds = annotation.bounds.offsetBy(dx: delta.x, dy: delta.y)
            guard let to = NoteService.positionSnapshot(
                bounds: translatedBounds,
                anchor: targetCenter,
                on: page,
                for: annotation
            ) else { return nil }
            return .setNotePosition(
                annotation: annotation,
                pageIndex: note.pageIndex,
                from: from,
                to: to
            )
        }
        guard changes.count == annotations.count,
              performMarkupEdit(MarkupEdit(changes: changes))
        else { return false }

        return true
    }

    // MARK: - Creating

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

        if let marker = noteMarkers.first(where: {
            $0.pageIndex == draft.pageIndex
                && abs($0.center.x - draft.bounds.midX) <= 0.5
                && abs($0.center.y - draft.bounds.midY) <= 0.5
                && NoteService.excerpt(of: $0.annotation) == draft.excerpt
                && NoteService.isPageLevel($0.annotation) == draft.isPageLevel
                && (!NoteService.isYoPDFNote($0.annotation)
                    || $0.threadEntries.allSatisfy {
                        NoteService.yoPDFThreadIdentityStatus(of: $0.annotation) != .conflicting
                    })
        }),
        let existingThread = NoteService.selection(
            for: marker.annotation,
            on: page,
            pageIndex: draft.pageIndex,
            marker: marker
        ) {
            return addThought(to: existingThread, contents: text, style: style)
        }

        guard let annotation = NoteService.annotation(
            for: draft,
            contents: text,
            style: style,
            on: page
        ) else { return .failure(.emptyContents) }
        NoteService.setYoPDFThreadIdentity(UUID(), order: 0, on: annotation)

        let edit = MarkupEdit(changes: [
            .insert(annotation: annotation, pageIndex: draft.pageIndex)
        ])
        guard performMarkupEdit(edit) else { return .failure(.permissionDenied) }

        guard let selection = NoteService.selection(
            for: annotation,
            on: page,
            pageIndex: draft.pageIndex
        ) else { return .failure(.annotationUnavailable) }
        return .success(selection)
    }

    @discardableResult
    public func addThought(
        to group: NoteSelection,
        contents: String,
        style: NoteStickerStyle
    ) -> Result<NoteSelection, NoteEditError> {
        guard let document else { return .failure(.noDocument) }
        guard isAttached(group) else { return .failure(.annotationUnavailable) }
        let isShuaThread = NoteService.isShuaThought(group.annotation)
        let isYoPDFThread = NoteService.isYoPDFNote(group.annotation)
        guard (isShuaThread || isYoPDFThread), document.allowsCommenting
        else { return .failure(.permissionDenied) }
        if isShuaThread {
            if case .conflicting = NoteService.shuaThoughtGroupIdentityStatus(of: group.annotation) {
                return .failure(.conflictingIdentity)
            }
            if NoteService.hasConflictingShuaIdentity(in: group) {
                return .failure(.conflictingIdentity)
            }
        } else {
            let statuses = group.threadEntries.map {
                NoteService.yoPDFThreadIdentityStatus(of: $0.annotation)
            }
            let threadIDs = Set(statuses.compactMap { status -> UUID? in
                guard case let .identified(id) = status else { return nil }
                return id
            })
            if statuses.contains(.conflicting)
                || threadIDs.count > 1
                || (!threadIDs.isEmpty && statuses.contains(.legacy)) {
                return .failure(.conflictingIdentity)
            }
        }

        let text = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.emptyContents) }
        guard let page = document.page(at: group.pageIndex), page.document === document else {
            return .failure(.pageUnavailable)
        }
        let identityChanges: [MarkupEditChange]
        let annotation: PDFAnnotation
        if NoteService.isShuaThought(group.annotation) {
            guard let plan = NoteService.groupedThoughtPlan(
                for: group,
                contents: text,
                style: style,
                on: page
            ) else { return .failure(.annotationUnavailable) }
            identityChanges = plan.identityChanges.map {
                .setShuaThoughtIdentity(
                    annotation: $0.annotation,
                    pageIndex: group.pageIndex,
                    from: $0.from,
                    to: $0.to
                )
            }
            annotation = plan.annotation
        } else if NoteService.isYoPDFNote(group.annotation) {
            guard let plan = NoteService.groupedYoPDFNotePlan(
                for: group,
                contents: text,
                style: style,
                on: page
            ) else { return .failure(.annotationUnavailable) }
            identityChanges = []
            annotation = plan.annotation
        } else {
            return .failure(.permissionDenied)
        }
        let edit = MarkupEdit(changes: identityChanges + [
            .insert(annotation: annotation, pageIndex: group.pageIndex),
        ])
        guard performMarkupEdit(edit) else { return .failure(.permissionDenied) }

        guard let updatedGroup = noteSelection(at: group.center, on: page) else {
            return .failure(.annotationUnavailable)
        }
        return .success(updatedGroup)
    }

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

    @discardableResult
    public func addThought(
        to group: NoteSelection,
        contents: String,
        paperColor: NotePaperColor
    ) -> Result<NoteSelection, NoteEditError> {
        addThought(
            to: group,
            contents: contents,
            style: NoteStickerStyle(motif: .plain, palette: paperColor)
        )
    }

    // MARK: - Editing

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

        guard let selection = NoteService.selection(
            for: note.annotation,
            on: page,
            pageIndex: note.pageIndex
        ) else { return .failure(.annotationUnavailable) }
        return .success(selection)
    }

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
        return performMarkupEdit(edit)
    }

    // MARK: - Markers

    public func refreshNoteMarkers() {
        guard let document else {
            noteMarkers = []
            return
        }
        noteMarkers = NoteService.markers(in: document)
    }
}

extension PDFDocumentModel {

    // MARK: - Availability

    public var canCreateNote: Bool {
        resourceSession.canCreateNote
    }

    public var canAddSelectionNote: Bool {
        paneModel.canAddSelectionNote
    }

    // MARK: - Drafts

    public func selectionNoteDraft() -> NoteDraft? {
        paneModel.selectionNoteDraft()
    }

    public func pageNoteDraft(at point: CGPoint, on page: PDFPage) -> NoteDraft? {
        resourceSession.pageNoteDraft(at: point, on: page)
    }

    // MARK: - Reading

    public func noteSelection(at point: CGPoint, on page: PDFPage) -> NoteSelection? {
        resourceSession.noteSelection(at: point, on: page)
    }

    public func noteSelection(
        forThreadEntry entry: NoteThreadEntry,
        in group: NoteSelection
    ) -> NoteSelection? {
        resourceSession.noteSelection(forThreadEntry: entry, in: group)
    }

    public func isCurrent(_ draft: NoteDraft) -> Bool {
        resourceSession.isCurrent(draft)
    }

    public func isAttached(_ note: NoteSelection) -> Bool {
        resourceSession.isAttached(note)
    }

    public func notePermissions(for note: NoteSelection) -> NotePermissions {
        resourceSession.notePermissions(for: note)
    }

    @discardableResult
    public func moveNoteMarker(_ note: NoteSelection, to proposedCenter: CGPoint) -> Bool {
        let success = resourceSession.moveNoteMarker(note, to: proposedCenter)
        if success {
            paneModel.clearMarkupSelection()
        }
        return success
    }

    // MARK: - Creating

    @discardableResult
    public func addNote(
        _ draft: NoteDraft,
        contents: String,
        style: NoteStickerStyle
    ) -> Result<NoteSelection, NoteEditError> {
        let result = resourceSession.addNote(draft, contents: contents, style: style)
        if case .success = result {
            paneModel.clearMarkupSelection()
            paneModel.updateSelection(nil)
        }
        return result
    }

    @discardableResult
    public func addNote(
        _ draft: NoteDraft,
        contents: String,
        paperColor: NotePaperColor
    ) -> Result<NoteSelection, NoteEditError> {
        let result = resourceSession.addNote(draft, contents: contents, paperColor: paperColor)
        if case .success = result {
            paneModel.clearMarkupSelection()
            paneModel.updateSelection(nil)
        }
        return result
    }

    @discardableResult
    public func addThought(
        to group: NoteSelection,
        contents: String,
        style: NoteStickerStyle
    ) -> Result<NoteSelection, NoteEditError> {
        let result = resourceSession.addThought(to: group, contents: contents, style: style)
        if case .success = result {
            paneModel.clearMarkupSelection()
            paneModel.updateSelection(nil)
        }
        return result
    }

    @discardableResult
    public func addThought(
        to group: NoteSelection,
        contents: String,
        paperColor: NotePaperColor
    ) -> Result<NoteSelection, NoteEditError> {
        let result = resourceSession.addThought(to: group, contents: contents, paperColor: paperColor)
        if case .success = result {
            paneModel.clearMarkupSelection()
            paneModel.updateSelection(nil)
        }
        return result
    }

    // MARK: - Editing

    @discardableResult
    public func updateNote(
        _ note: NoteSelection,
        contents: String,
        style: NoteStickerStyle
    ) -> Result<NoteSelection, NoteEditError> {
        let result = resourceSession.updateNote(note, contents: contents, style: style)
        if case .success = result {
            paneModel.clearMarkupSelection()
        }
        return result
    }

    @discardableResult
    public func updateNote(
        _ note: NoteSelection,
        contents: String,
        paperColor: NotePaperColor
    ) -> Result<NoteSelection, NoteEditError> {
        let result = resourceSession.updateNote(note, contents: contents, paperColor: paperColor)
        if case .success = result {
            paneModel.clearMarkupSelection()
        }
        return result
    }

    // MARK: - Deleting

    @discardableResult
    public func deleteNote(_ note: NoteSelection) -> Bool {
        let success = resourceSession.deleteNote(note)
        if success {
            paneModel.clearMarkupSelection()
        }
        return success
    }

    // MARK: - Markers

    public func refreshNoteMarkers() {
        resourceSession.refreshNoteMarkers()
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
        case .conflictingIdentity:
            return "This Shua note has conflicting group identity data. No thought was added."
        case .permissionDenied:
            return "This note is protected and cannot be changed."
        }
    }
}
