import AppKit
import PDFKit

/// One reversible change to the annotations of the open document.
///
/// The record stores page indices instead of `PDFPage` references so a history
/// entry can be validated against whatever document is currently loaded. It is
/// cleared whenever the document is replaced: an annotation object belongs to
/// the `PDFDocument` that created it, and replaying an edit after a document
/// reload would otherwise mutate an old in-memory document. In-place saves
/// keep the live document loaded, so they can retain this history.
enum MarkupEditChange {
    case insert(annotation: PDFAnnotation, pageIndex: Int)
    case remove(annotation: PDFAnnotation, pageIndex: Int)
    case recolor(
        annotation: PDFAnnotation,
        pageIndex: Int,
        from: NSColor,
        to: NSColor
    )
    /// A note body change. `/Contents` is the only entry this touches, so a
    /// LockedContents annotation must be refused here even though its paper
    /// colour and deletion stay editable.
    case setContents(
        annotation: PDFAnnotation,
        pageIndex: Int,
        from: String?,
        to: String?
    )
    /// A note appearance change, including ownership of the presentation.
    ///
    /// The snapshots record which YoPDF keys existed and the exact `/C` colour,
    /// so Undo can remove keys the edit introduced. That makes adopting a
    /// third-party note reversible: its native icon and native hit target come
    /// back instead of becoming a YoPDF Simple Paper note. None of these keys is
    /// `/Contents`, so LockedContents permits the edit and Locked/ReadOnly do
    /// not.
    case setNoteStyle(
        annotation: PDFAnnotation,
        pageIndex: Int,
        from: NoteStyleSnapshot,
        to: NoteStyleSnapshot
    )
    /// Promotes a legacy Shua geometry stack to explicit, reversible thought
    /// identity so later styling or page-edge clamping cannot split the group.
    case setShuaThoughtIdentity(
        annotation: PDFAnnotation,
        pageIndex: Int,
        from: ShuaThoughtIdentitySnapshot,
        to: ShuaThoughtIdentitySnapshot
    )
    /// Moving a note keeps its standard PDF rectangle and YoPDF's normalized
    /// marker anchor in one reversible edit.
    case setNotePosition(
        annotation: PDFAnnotation,
        pageIndex: Int,
        from: NotePositionSnapshot,
        to: NotePositionSnapshot
    )

    var pageIndex: Int {
        switch self {
        case let .insert(_, pageIndex),
             let .remove(_, pageIndex),
             let .recolor(_, pageIndex, _, _),
             let .setContents(_, pageIndex, _, _),
             let .setNoteStyle(_, pageIndex, _, _),
             let .setShuaThoughtIdentity(_, pageIndex, _, _),
             let .setNotePosition(_, pageIndex, _, _):
            return pageIndex
        }
    }

    var annotation: PDFAnnotation {
        switch self {
        case let .insert(annotation, _),
             let .remove(annotation, _),
             let .recolor(annotation, _, _, _),
             let .setContents(annotation, _, _, _),
             let .setNoteStyle(annotation, _, _, _),
             let .setShuaThoughtIdentity(annotation, _, _, _),
             let .setNotePosition(annotation, _, _, _):
            return annotation
        }
    }
}

/// A user-visible edit, which may touch several pages.
///
/// A selection that spans pages becomes one entry with several insert/remove
/// changes, so a single Undo removes the whole mark rather than one page of it.
struct MarkupEdit {
    let changes: [MarkupEditChange]

    var pageIndices: [Int] {
        Array(Set(changes.map(\.pageIndex))).sorted()
    }

    /// Consecutive recolours of the same annotation are one action.
    ///
    /// The custom colour picker reports intermediate colours while the user
    /// moves through the spectrum. Treating each report as a separate undo step
    /// would make ⌘Z walk back through the colour wheel; merging keeps the
    /// gesture as one edit.
    func coalescing(_ next: MarkupEdit) -> MarkupEdit? {
        guard changes.count == 1,
              next.changes.count == 1,
              case let .recolor(firstAnnotation, firstPage, firstFrom, firstTo) = changes[0],
              case let .recolor(secondAnnotation, secondPage, secondFrom, secondTo) = next.changes[0],
              firstAnnotation === secondAnnotation,
              firstPage == secondPage,
              Self.sameColor(firstTo, secondFrom)
        else { return nil }

        return MarkupEdit(changes: [
            .recolor(
                annotation: firstAnnotation,
                pageIndex: firstPage,
                from: firstFrom,
                to: secondTo
            )
        ])
    }

    private static func sameColor(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let left = lhs.usingColorSpace(.sRGB),
              let right = rhs.usingColorSpace(.sRGB)
        else { return false }
        return abs(left.redComponent - right.redComponent) < 0.0001
            && abs(left.greenComponent - right.greenComponent) < 0.0001
            && abs(left.blueComponent - right.blueComponent) < 0.0001
    }
}

extension PDFDocumentModel {

    // MARK: - Adding

    /// The colour the next new mark of `kind` will use.
    public func defaultMarkupColor(for kind: MarkupKind) -> NSColor {
        markupPreferences.color(for: kind)
    }

    /// Persists the default for new marks of `kind`.
    ///
    /// Deliberately separate from recolouring an existing annotation: changing
    /// an existing mark is a document edit, changing this is an application
    /// preference, and one must never imply the other.
    @discardableResult
    public func setDefaultMarkupColor(_ color: NSColor, for kind: MarkupKind) -> Bool {
        markupPreferences.setColor(color, for: kind)
    }

    /// Whether a mark of `kind` can be created from the current selection.
    public func canAddMarkup(_ kind: MarkupKind) -> Bool {
        guard let document, document.allowsCommenting, let selection = currentSelection else {
            return false
        }
        let text = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty
    }

    /// Adds a standard markup annotation using the persisted default colour.
    ///
    /// All page placements of a cross-page selection are applied as one edit, so
    /// Undo removes the entire selection rather than the last page of it.
    @discardableResult
    public func addMarkup(_ kind: MarkupKind) -> HighlightService.Summary? {
        guard let document,
              let selection = currentSelection,
              canAddMarkup(kind),
              let creation = try? HighlightService.createMarkup(
                  kind,
                  from: selection,
                  in: document,
                  color: defaultMarkupColor(for: kind)
              )
        else { return nil }

        let edit = MarkupEdit(changes: creation.placements.map {
            .insert(annotation: $0.annotation, pageIndex: $0.pageIndex)
        })
        guard performMarkupEdit(edit) else { return nil }
        updateSelection(nil)
        return creation.summary
    }

    // MARK: - Selection

    /// Hit-tests annotations by their painted quads, not by their bounds.
    ///
    /// Returns `true` when an annotation was selected. A miss clears the current
    /// markup selection but leaves the text selection alone: clicking the page
    /// background is the normal way to dismiss the annotation controls.
    @discardableResult
    public func selectMarkup(at point: CGPoint, on page: PDFPage) -> Bool {
        guard let document,
              page.document === document,
              let pageIndex = Self.validPageIndex(for: page, in: document)
        else {
            selectedMarkup = nil
            return false
        }

        // Last annotation wins: PDFKit draws later annotations on top.
        for annotation in page.annotations.reversed() {
            guard annotation.shouldDisplay,
                  let kind = MarkupKind(annotation: annotation),
                  MarkupGeometry.contains(annotation, point: point),
                  let selection = MarkupSelection(
                      annotation: annotation,
                      kind: kind,
                      pageIndex: pageIndex
                  )
            else { continue }
            selectedMarkup = selection
            updateSelection(nil)
            return true
        }

        selectedMarkup = nil
        return false
    }

    public func clearMarkupSelection() {
        selectedMarkup = nil
    }

    /// True when the selected annotation passes every permission check for the
    /// document and page it is currently attached to.
    public var canModifySelectedMarkup: Bool {
        selectedMarkupContext() != nil
    }

    /// True when something is selected but cannot be changed. The UI uses this
    /// to explain why the editing controls are disabled rather than hiding them.
    public var selectedMarkupIsProtected: Bool {
        selectedMarkup != nil && !canModifySelectedMarkup
    }

    // MARK: - Recolour

    /// Recolours the selected annotation without touching the new-mark default.
    ///
    /// A fully transparent or unconvertible colour is refused before anything is
    /// changed. Repeating the current colour is a no-op and does not create an
    /// undo entry.
    @discardableResult
    public func recolorSelectedMarkup(to color: NSColor) -> Bool {
        guard let normalized = MarkupColorPalette.normalized(color),
              let context = selectedMarkupContext()
        else { return false }

        let currentHex = MarkupColorPalette.hex(from: context.annotation.color)
        let newHex = MarkupColorPalette.hex(from: normalized)
        if currentHex != nil, currentHex == newHex {
            return true
        }

        let edit = MarkupEdit(changes: [
            .recolor(
                annotation: context.annotation,
                pageIndex: context.pageIndex,
                from: context.annotation.color,
                to: normalized
            )
        ])
        guard performMarkupEdit(edit, coalescingRecolour: true) else { return false }
        selectedMarkup = MarkupSelection(
            annotation: context.annotation,
            kind: context.kind,
            pageIndex: context.pageIndex
        )
        return true
    }

    // MARK: - Delete and convert

    @discardableResult
    public func deleteSelectedMarkup() -> Bool {
        guard let context = selectedMarkupContext() else { return false }
        let edit = MarkupEdit(changes: [
            .remove(annotation: context.annotation, pageIndex: context.pageIndex)
        ])
        guard performMarkupEdit(edit) else { return false }
        selectedMarkup = nil
        return true
    }

    /// Replaces the selected annotation with the other markup subtype.
    ///
    /// The replacement keeps bounds, quads, colour and copied metadata; the two
    /// changes are one undo entry, so ⌘Z restores the original subtype.
    @discardableResult
    public func convertSelectedMarkup() -> Bool {
        guard let context = selectedMarkupContext(),
              let replacement = try? HighlightService.replacement(
                  for: context.annotation,
                  as: context.kind.converted
              )
        else { return false }

        let edit = MarkupEdit(changes: [
            .remove(annotation: context.annotation, pageIndex: context.pageIndex),
            .insert(annotation: replacement, pageIndex: context.pageIndex)
        ])
        guard performMarkupEdit(edit) else { return false }
        selectedMarkup = MarkupSelection(
            annotation: replacement,
            kind: context.kind.converted,
            pageIndex: context.pageIndex
        )
        return true
    }

    // MARK: - Undo and redo

    @discardableResult
    public func undoMarkup() -> Bool {
        guard let edit = markupUndoStack.last else { return false }
        switch applyMarkupEdit(edit, forward: false) {
        case .applied:
            markupUndoStack.removeLast()
            markupRedoStack.append(edit)
            selectedMarkup = nil
            updateMarkupAvailability()
            markEdited()
            return true
        case .permissionDenied:
            // The history is still valid; the annotation is simply protected at
            // the moment. Keep the entry, the selection and the dirty state so
            // that unlocking the annotation makes the same Undo available again.
            return false
        case .invalidHistory:
            resetMarkupHistory()
            selectedMarkup = nil
            return false
        }
    }

    @discardableResult
    public func redoMarkup() -> Bool {
        guard let edit = markupRedoStack.last else { return false }
        switch applyMarkupEdit(edit, forward: true) {
        case .applied:
            markupRedoStack.removeLast()
            markupUndoStack.append(edit)
            selectedMarkup = nil
            updateMarkupAvailability()
            markEdited()
            return true
        case .permissionDenied:
            // See `undoMarkup`: a protected annotation does not invalidate the
            // redo history.
            return false
        case .invalidHistory:
            resetMarkupHistory()
            selectedMarkup = nil
            return false
        }
    }

    // MARK: - Edit plumbing

    private struct SelectedMarkupContext {
        let annotation: PDFAnnotation
        let kind: MarkupKind
        let pageIndex: Int
    }

    private func selectedMarkupContext() -> SelectedMarkupContext? {
        guard let document,
              let selected = selectedMarkup,
              let page = document.page(at: selected.pageIndex),
              let kind = MarkupKind(annotation: selected.annotation),
              MarkupPermissions.canModify(selected.annotation, in: document, on: page),
              document.index(for: page) == selected.pageIndex
        else { return nil }
        return SelectedMarkupContext(
            annotation: selected.annotation,
            kind: kind,
            pageIndex: selected.pageIndex
        )
    }

    /// Applies a new edit, registers it for Undo and advances the dirty state.
    ///
    /// The edit is validated before any change is made, so a failed call cannot
    /// leave half a cross-page annotation behind.
    ///
    /// Internal rather than private so `NoteEditing` uses the same pipeline
    /// instead of a second mutation path.
    func performMarkupEdit(
        _ edit: MarkupEdit,
        coalescingRecolour: Bool = false
    ) -> Bool {
        guard applyMarkupEdit(edit, forward: true) == .applied else { return false }

        if coalescingRecolour,
           let previous = markupUndoStack.last,
           let merged = previous.coalescing(edit) {
            markupUndoStack[markupUndoStack.count - 1] = merged
        } else {
            markupUndoStack.append(edit)
        }
        markupRedoStack.removeAll()
        updateMarkupAvailability()
        markEdited()
        return true
    }

    private enum MarkupReplayOutcome {
        case applied
        case permissionDenied
        case invalidHistory
    }

    /// Replays an edit against the current document.
    ///
    /// Every change is checked first. A stale history entry — an annotation
    /// another caller removed, or a page that no longer exists — is treated as
    /// an unusable history rather than as a reason to mutate some other page.
    /// Permission checks run in the same preflight pass and cover the whole
    /// edit, so a locked annotation on one page blocks a cross-page Undo before
    /// any page is touched.
    private func applyMarkupEdit(_ edit: MarkupEdit, forward: Bool) -> MarkupReplayOutcome {
        guard let document, !edit.changes.isEmpty else { return .invalidHistory }

        var pages: [Int: PDFPage] = [:]
        for change in edit.changes {
            guard let page = document.page(at: change.pageIndex),
                  page.document === document
            else { return .invalidHistory }
            pages[change.pageIndex] = page

            let annotation = change.annotation
            switch change {
            case .insert:
                if forward {
                    // Redo of an insert, or the insertion half of a conversion.
                    guard annotation.page == nil,
                          !page.annotations.contains(where: { $0 === annotation })
                    else { return .invalidHistory }
                } else {
                    // Undo of an add: the mark must still be on this page.
                    guard annotation.page === page,
                          page.annotations.contains(where: { $0 === annotation })
                    else { return .invalidHistory }
                }
            case .remove:
                if forward {
                    // Redo of a delete: the mark must be there to remove.
                    guard annotation.page === page,
                          page.annotations.contains(where: { $0 === annotation })
                    else { return .invalidHistory }
                } else {
                    // Undo of a delete: the mark must still be detached.
                    guard annotation.page == nil,
                          !page.annotations.contains(where: { $0 === annotation })
                    else { return .invalidHistory }
                }
            case .recolor, .setNoteStyle, .setShuaThoughtIdentity, .setNotePosition:
                guard annotation.page === page,
                      page.annotations.contains(where: { $0 === annotation })
                else { return .invalidHistory }
            case .setContents:
                guard annotation.page === page,
                      page.annotations.contains(where: { $0 === annotation })
                else { return .invalidHistory }
            }

            // The same `/F` and document rules as a direct edit. This also
            // covers annotations that are currently detached, so undoing a
            // delete cannot restore a mark whose flags have since been locked.
            // Contents have one extra bit: LockedContents blocks the body but
            // not the paper colour or deletion of the note. The document-level
            // commenting permission applies to every change.
            switch change {
            case .setContents:
                guard document.allowsCommenting,
                      MarkupPermissions.allowsContentsChanges(annotation)
                else { return .permissionDenied }
            case .insert, .remove, .recolor, .setNoteStyle, .setShuaThoughtIdentity, .setNotePosition:
                guard MarkupPermissions.allowsAnnotationChanges(annotation, in: document)
                else { return .permissionDenied }
            }
        }

        for change in forward ? edit.changes : edit.changes.reversed() {
            guard let page = pages[change.pageIndex] else { return .invalidHistory }
            switch change {
            case let .insert(annotation, _):
                if forward {
                    page.addAnnotation(annotation)
                } else {
                    removeAnnotationAndPopup(annotation, from: page)
                }
            case let .remove(annotation, _):
                if forward {
                    removeAnnotationAndPopup(annotation, from: page)
                } else {
                    page.addAnnotation(annotation)
                    restorePopup(of: annotation, on: page)
                }
            case let .recolor(annotation, _, from, to):
                annotation.color = forward ? to : from
                annotation.modificationDate = Date()
            case let .setContents(annotation, _, from, to):
                NoteService.setContents(forward ? to : from, on: annotation)
            case let .setNoteStyle(annotation, _, from, to):
                NoteService.applyStyleSnapshot(forward ? to : from, to: annotation)
            case let .setShuaThoughtIdentity(annotation, _, from, to):
                NoteService.applyShuaIdentitySnapshot(forward ? to : from, to: annotation)
            case let .setNotePosition(annotation, _, from, to):
                NoteService.applyPositionSnapshot(forward ? to : from, to: annotation)
            }
        }

        noteAnnotationsChanged(on: edit.pageIndices)
        return .applied
    }

    private func resetMarkupHistory() {
        markupUndoStack.removeAll()
        markupRedoStack.removeAll()
        updateMarkupAvailability()
    }

    private func updateMarkupAvailability() {
        canUndoMarkup = !markupUndoStack.isEmpty
        canRedoMarkup = !markupRedoStack.isEmpty
    }

    private func noteAnnotationsChanged(on pageIndices: [Int]) {
        changedAnnotationPageIndices = Array(Set(pageIndices)).sorted()
        annotationRevision &+= 1
        refreshNoteMarkers()
    }

    /// Removes an annotation together with the popup PDFKit may have attached.
    ///
    /// A `/Text` annotation is commonly paired with a `/Popup` child. Removing
    /// only the parent leaves the popup behind as an empty, unclickable icon, so
    /// both objects go in the same undoable step.
    func removeAnnotationAndPopup(_ annotation: PDFAnnotation, from page: PDFPage) {
        if let popup = annotation.popup,
           page.annotations.contains(where: { $0 === popup }) {
            page.removeAnnotation(popup)
        }
        page.removeAnnotation(annotation)
    }

    /// Puts back the popup that belonged to a restored annotation.
    ///
    /// PDFKit keeps the popup object on the annotation, so undoing a delete can
    /// reattach it. It is only re-added when it is not already on the page.
    func restorePopup(of annotation: PDFAnnotation, on page: PDFPage) {
        guard let popup = annotation.popup,
              !page.annotations.contains(where: { $0 === popup })
        else { return }
        page.addAnnotation(popup)
    }

    private static func validPageIndex(for page: PDFPage, in document: PDFDocument) -> Int? {
        let index = document.index(for: page)
        return index >= 0 ? index : nil
    }
}
