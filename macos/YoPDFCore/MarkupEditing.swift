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

struct SelectedMarkupContext {
    let annotation: PDFAnnotation
    let kind: MarkupKind
    let pageIndex: Int
}

extension PDFResourceSession {

    // MARK: - Adding

    public func defaultMarkupColor(for kind: MarkupKind) -> NSColor {
        markupPreferences.color(for: kind)
    }

    @discardableResult
    public func setDefaultMarkupColor(_ color: NSColor, for kind: MarkupKind) -> Bool {
        markupPreferences.setColor(color, for: kind)
    }

    public func canAddMarkup(_ kind: MarkupKind, from selection: PDFSelection?) -> Bool {
        guard let document, document.allowsCommenting, let selection else {
            return false
        }
        let text = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty
    }

    @discardableResult
    public func addMarkup(_ kind: MarkupKind, from selection: PDFSelection?) -> HighlightService.Summary? {
        guard let document,
              let selection,
              canAddMarkup(kind, from: selection),
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
        return creation.summary
    }

    // MARK: - Recolour, Delete, Convert

    @discardableResult
    public func recolorMarkup(
        _ annotation: PDFAnnotation,
        on pageIndex: Int,
        to color: NSColor,
        coalescing: Bool = true
    ) -> Bool {
        guard let normalized = MarkupColorPalette.normalized(color),
              let document,
              let page = document.page(at: pageIndex),
              MarkupPermissions.canModify(annotation, in: document, on: page),
              document.index(for: page) == pageIndex
        else { return false }

        let currentHex = MarkupColorPalette.hex(from: annotation.color)
        let newHex = MarkupColorPalette.hex(from: normalized)
        if currentHex != nil, currentHex == newHex {
            return true
        }

        let edit = MarkupEdit(changes: [
            .recolor(
                annotation: annotation,
                pageIndex: pageIndex,
                from: annotation.color,
                to: normalized
            )
        ])
        return performMarkupEdit(edit, coalescingRecolour: coalescing)
    }

    @discardableResult
    public func deleteMarkup(_ annotation: PDFAnnotation, on pageIndex: Int) -> Bool {
        guard let document,
              let page = document.page(at: pageIndex),
              MarkupPermissions.canModify(annotation, in: document, on: page),
              document.index(for: page) == pageIndex
        else { return false }

        let edit = MarkupEdit(changes: [
            .remove(annotation: annotation, pageIndex: pageIndex)
        ])
        return performMarkupEdit(edit)
    }

    @discardableResult
    public func convertMarkup(_ annotation: PDFAnnotation, on pageIndex: Int) -> PDFAnnotation? {
        guard let document,
              let page = document.page(at: pageIndex),
              let currentKind = MarkupKind(annotation: annotation),
              MarkupPermissions.canModify(annotation, in: document, on: page),
              document.index(for: page) == pageIndex,
              let replacement = try? HighlightService.replacement(
                  for: annotation,
                  as: currentKind.converted
              )
        else { return nil }

        let edit = MarkupEdit(changes: [
            .remove(annotation: annotation, pageIndex: pageIndex),
            .insert(annotation: replacement, pageIndex: pageIndex)
        ])
        guard performMarkupEdit(edit) else { return nil }
        return replacement
    }

    // MARK: - Undo and redo

    @discardableResult
    public func undoMarkup() -> Bool {
        guard let edit = markupUndoStack.last else { return false }
        switch applyMarkupEdit(edit, forward: false) {
        case .applied:
            markupUndoStack.removeLast()
            markupRedoStack.append(edit)
            updateMarkupAvailability()
            markEdited()
            return true
        case .permissionDenied:
            return false
        case .invalidHistory:
            resetMarkupHistory()
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
            updateMarkupAvailability()
            markEdited()
            return true
        case .permissionDenied:
            return false
        case .invalidHistory:
            resetMarkupHistory()
            return false
        }
    }

    // MARK: - Edit plumbing

    @discardableResult
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

    enum MarkupReplayOutcome {
        case applied
        case permissionDenied
        case invalidHistory
    }

    func applyMarkupEdit(_ edit: MarkupEdit, forward: Bool) -> MarkupReplayOutcome {
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
                    guard annotation.page == nil,
                          !page.annotations.contains(where: { $0 === annotation })
                    else { return .invalidHistory }
                } else {
                    guard annotation.page === page,
                          page.annotations.contains(where: { $0 === annotation })
                    else { return .invalidHistory }
                }
            case .remove:
                if forward {
                    guard annotation.page === page,
                          page.annotations.contains(where: { $0 === annotation })
                    else { return .invalidHistory }
                } else {
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

            switch change {
            case .setContents:
                guard document.allowsCommenting,
                      MarkupPermissions.allowsContentsChanges(annotation)
                else { return .permissionDenied }
            case .insert, .remove, .recolor, .setNoteStyle, .setShuaThoughtIdentity,
                 .setNotePosition:
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

    func updateMarkupAvailability() {
        canUndoMarkup = !markupUndoStack.isEmpty
        canRedoMarkup = !markupRedoStack.isEmpty
    }

    func resetMarkupHistory() {
        markupUndoStack.removeAll()
        markupRedoStack.removeAll()
        updateMarkupAvailability()
    }

    func noteAnnotationsChanged(on pageIndices: [Int]) {
        changedAnnotationPageIndices = Array(Set(pageIndices)).sorted()
        annotationRevision &+= 1
        refreshNoteMarkers()
    }

    func removeAnnotationAndPopup(_ annotation: PDFAnnotation, from page: PDFPage) {
        if let popup = annotation.popup,
           page.annotations.contains(where: { $0 === popup }) {
            page.removeAnnotation(popup)
        }
        page.removeAnnotation(annotation)
    }

    func restorePopup(of annotation: PDFAnnotation, on page: PDFPage) {
        guard let popup = annotation.popup,
              !page.annotations.contains(where: { $0 === popup })
        else { return }
        page.addAnnotation(popup)
    }

    static func validPageIndex(for page: PDFPage, in document: PDFDocument) -> Int? {
        let index = document.index(for: page)
        return index >= 0 ? index : nil
    }
}

extension PDFDocumentModel {

    // MARK: - Adding

    public func defaultMarkupColor(for kind: MarkupKind) -> NSColor {
        resourceSession.defaultMarkupColor(for: kind)
    }

    @discardableResult
    public func setDefaultMarkupColor(_ color: NSColor, for kind: MarkupKind) -> Bool {
        resourceSession.setDefaultMarkupColor(color, for: kind)
    }

    public func canAddMarkup(_ kind: MarkupKind) -> Bool {
        paneModel.canAddMarkup(kind)
    }

    @discardableResult
    public func addMarkup(_ kind: MarkupKind) -> HighlightService.Summary? {
        paneModel.addMarkup(kind)
    }

    // MARK: - Selection

    @discardableResult
    public func selectMarkup(at point: CGPoint, on page: PDFPage) -> Bool {
        paneModel.selectMarkup(at: point, on: page)
    }

    public func clearMarkupSelection() {
        paneModel.clearMarkupSelection()
    }

    public var canModifySelectedMarkup: Bool {
        paneModel.canModifySelectedMarkup
    }

    public var selectedMarkupIsProtected: Bool {
        paneModel.selectedMarkupIsProtected
    }

    // MARK: - Recolour

    @discardableResult
    public func recolorSelectedMarkup(to color: NSColor, coalescing: Bool = true) -> Bool {
        paneModel.recolorSelectedMarkup(to: color, coalescing: coalescing)
    }

    @discardableResult
    public func recolorSelectedMarkup(to color: NSColor) -> Bool {
        paneModel.recolorSelectedMarkup(to: color, coalescing: true)
    }

    // MARK: - Delete and convert

    @discardableResult
    public func deleteSelectedMarkup() -> Bool {
        paneModel.deleteSelectedMarkup()
    }

    @discardableResult
    public func convertSelectedMarkup() -> Bool {
        paneModel.convertSelectedMarkup()
    }

    // MARK: - Undo and redo

    @discardableResult
    public func undoMarkup() -> Bool {
        let success = resourceSession.undoMarkup()
        if success {
            paneModel.clearMarkupSelection()
        }
        return success
    }

    @discardableResult
    public func redoMarkup() -> Bool {
        let success = resourceSession.redoMarkup()
        if success {
            paneModel.clearMarkupSelection()
        }
        return success
    }

    func performMarkupEdit(
        _ edit: MarkupEdit,
        coalescingRecolour: Bool = false
    ) -> Bool {
        resourceSession.performMarkupEdit(edit, coalescingRecolour: coalescingRecolour)
    }

    func removeAnnotationAndPopup(_ annotation: PDFAnnotation, from page: PDFPage) {
        resourceSession.removeAnnotationAndPopup(annotation, from: page)
    }

    func restorePopup(of annotation: PDFAnnotation, on page: PDFPage) {
        resourceSession.restorePopup(of: annotation, on: page)
    }
}
