import AppKit
import PDFKit

/// One reversible change to the annotations of the open document.
///
/// The record stores page indices instead of `PDFPage` references so a history
/// entry can be validated against whatever document is currently loaded. It is
/// still cleared whenever the document is replaced: an annotation object belongs
/// to the `PDFDocument` that created it, and replaying an edit after a save
/// would otherwise mutate an old in-memory document.
enum MarkupEditChange {
    case insert(annotation: PDFAnnotation, pageIndex: Int)
    case remove(annotation: PDFAnnotation, pageIndex: Int)
    case recolor(
        annotation: PDFAnnotation,
        pageIndex: Int,
        from: NSColor,
        to: NSColor
    )

    var pageIndex: Int {
        switch self {
        case let .insert(_, pageIndex),
             let .remove(_, pageIndex),
             let .recolor(_, pageIndex, _, _):
            return pageIndex
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
        guard applyMarkupEdit(edit, forward: false) else {
            resetMarkupHistory()
            selectedMarkup = nil
            return false
        }
        markupUndoStack.removeLast()
        markupRedoStack.append(edit)
        selectedMarkup = nil
        updateMarkupAvailability()
        markEdited()
        return true
    }

    @discardableResult
    public func redoMarkup() -> Bool {
        guard let edit = markupRedoStack.last else { return false }
        guard applyMarkupEdit(edit, forward: true) else {
            resetMarkupHistory()
            selectedMarkup = nil
            return false
        }
        markupRedoStack.removeLast()
        markupUndoStack.append(edit)
        selectedMarkup = nil
        updateMarkupAvailability()
        markEdited()
        return true
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
    private func performMarkupEdit(
        _ edit: MarkupEdit,
        coalescingRecolour: Bool = false
    ) -> Bool {
        guard applyMarkupEdit(edit, forward: true) else { return false }

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

    /// Replays an edit against the current document.
    ///
    /// Every change is checked first. A stale history entry — an annotation
    /// another caller removed, or a page that no longer exists — is treated as
    /// an unusable history rather than as a reason to mutate some other page.
    private func applyMarkupEdit(_ edit: MarkupEdit, forward: Bool) -> Bool {
        guard let document, !edit.changes.isEmpty else { return false }

        var pages: [Int: PDFPage] = [:]
        for change in edit.changes {
            guard let page = document.page(at: change.pageIndex),
                  page.document === document
            else { return false }
            pages[change.pageIndex] = page

            switch change {
            case let .insert(annotation, _):
                if forward {
                    if let attached = annotation.page, attached !== page { return false }
                    if page.annotations.contains(where: { $0 === annotation }) { return false }
                } else {
                    guard page.annotations.contains(where: { $0 === annotation }) else {
                        return false
                    }
                }
            case let .remove(annotation, _):
                if forward {
                    guard page.annotations.contains(where: { $0 === annotation }) else {
                        return false
                    }
                } else {
                    if let attached = annotation.page, attached !== page { return false }
                    if page.annotations.contains(where: { $0 === annotation }) { return false }
                }
            case let .recolor(annotation, _, _, _):
                guard page.annotations.contains(where: { $0 === annotation }) else {
                    return false
                }
            }
        }

        for change in forward ? edit.changes : edit.changes.reversed() {
            guard let page = pages[change.pageIndex] else { return false }
            switch change {
            case let .insert(annotation, _):
                if forward {
                    page.addAnnotation(annotation)
                } else {
                    page.removeAnnotation(annotation)
                }
            case let .remove(annotation, _):
                if forward {
                    page.removeAnnotation(annotation)
                } else {
                    page.addAnnotation(annotation)
                }
            case let .recolor(annotation, _, from, to):
                annotation.color = forward ? to : from
                annotation.modificationDate = Date()
            }
        }

        noteAnnotationsChanged(on: edit.pageIndices)
        return true
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
    }

    private static func validPageIndex(for page: PDFPage, in document: PDFDocument) -> Int? {
        let index = document.index(for: page)
        return index >= 0 ? index : nil
    }
}
