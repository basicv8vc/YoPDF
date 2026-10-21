import AppKit
import PDFKit

/// Turns a `PDFSelection` into standard PDF highlight or underline annotations.
///
/// The selection geometry and serialization rules are shared by both tools:
/// PDFKit's per-line rectangles become the annotation's `/QuadPoints`, and a
/// cross-page drag becomes one annotation per page. The service only constructs
/// and mutates PDF annotations; `PDFDocumentModel` is the single entry point
/// that also updates dirty state, undo history and document refresh state.
@MainActor
public enum HighlightService {

    /// The legacy P2a highlight colour, kept for callers that used the constant.
    /// New highlights use `MarkupColorPreferences` and default to `FFD60A`.
    public static let color = NSColor(srgbRed: 1.0, green: 0.8, blue: 0.0, alpha: 1.0)

    public enum Failure: Error, Equatable {
        /// Nothing selectable under the pointer: an image, a margin, a blank
        /// area. Creating an annotation here would produce a zero-area mark.
        case noSelectableText
        /// The selection resolved to no rectangle that could be marked up.
        case invalidGeometry
        /// The annotation no longer belongs to this document or page.
        case annotationNotInDocument
        /// ReadOnly, Locked or a document that does not allow commenting.
        case annotationIsProtected
    }

    /// What a successful call produced. Used by tests and by the reader to
    /// report where the mark went.
    public struct Summary: Equatable {
        /// Page indices in document order. More than one for a cross-page
        /// selection.
        public let pageIndices: [Int]
        /// One annotation per page, because an annotation belongs to exactly
        /// one page and must never be attached to a page it does not cover.
        public let annotationCount: Int
        /// One quad per selected line; the geometry other readers render.
        public let quadCount: Int
    }

    struct Placement {
        let page: PDFPage
        let annotation: PDFAnnotation
        let pageIndex: Int
    }

    struct Creation {
        let summary: Summary
        let placements: [Placement]
    }

    /// Adds a highlight for `selection` to `document`.
    ///
    /// Retained as the P2a compatibility entry point. It uses the same builder
    /// as `addMarkup(_:from:to:color:)`.
    @discardableResult
    public static func addHighlight(
        from selection: PDFSelection,
        to document: PDFDocument,
        color: NSColor? = nil
    ) throws -> Summary {
        try addMarkup(.highlight, from: selection, to: document, color: color)
    }

    /// Adds a standard `/Highlight` or `/Underline` annotation for `selection`.
    ///
    /// A selection spanning several pages becomes one annotation per page,
    /// each carrying only the quads that belong to it. A selection that
    /// resolves to no text, or to no usable geometry, throws and leaves the
    /// document untouched.
    @discardableResult
    public static func addMarkup(
        _ kind: MarkupKind,
        from selection: PDFSelection,
        to document: PDFDocument,
        color: NSColor? = nil
    ) throws -> Summary {
        let creation = try createMarkup(
            kind,
            from: selection,
            in: document,
            color: color
        )
        for placement in creation.placements {
            placement.page.addAnnotation(placement.annotation)
        }
        return creation.summary
    }

    /// Builds the placements without mutating the document.
    ///
    /// Keeping construction and insertion separate lets the model register one
    /// undo action for all pages before any annotation is added to a page. It is
    /// internal so the reader has no second public editing entry point.
    static func createMarkup(
        _ kind: MarkupKind,
        from selection: PDFSelection,
        in document: PDFDocument,
        color: NSColor? = nil
    ) throws -> Creation {
        let text = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.noSelectableText }
        guard selection.pages.allSatisfy({ $0.document === document }) else {
            throw Failure.invalidGeometry
        }

        let groups = try pageGroups(for: selection, in: document)
        let resolvedColor = MarkupColorPalette.annotationColor(
            color ?? MarkupColorPalette.color(fromHex: kind.defaultColorHex),
            for: kind
        )

        var placements: [Placement] = []
        var quadCount = 0
        for group in groups {
            let bounds = group.rects.dropFirst().reduce(group.rects[0]) { $0.union($1) }
            let annotation = PDFAnnotation(
                bounds: bounds,
                forType: kind.annotationSubtype,
                withProperties: nil
            )
            annotation.color = resolvedColor
            annotation.quadrilateralPoints = quadPoints(
                for: group.rects,
                relativeTo: bounds.origin
            )
            annotation.modificationDate = Date()
            placements.append(Placement(
                page: group.page,
                annotation: annotation,
                pageIndex: group.index
            ))
            quadCount += group.rects.count
        }

        return Creation(
            summary: Summary(
                pageIndices: groups.map(\.index),
                annotationCount: groups.count,
                quadCount: quadCount
            ),
            placements: placements
        )
    }

    /// The per-line rectangles a markup annotation would use, grouped by page.
    ///
    /// Exposed for tests: the geometry is the part that has to be right, and it
    /// is easier to assert on rectangles than on a rendered image.
    public static func lineRects(
        for selection: PDFSelection,
        on page: PDFPage
    ) -> [CGRect] {
        selection.selectionsByLine()
            .map { $0.bounds(for: page) }
            .filter(isUsable)
    }

    /// Converts an existing markup annotation to the other subtype.
    ///
    /// The new annotation keeps the old bounds and quads, colour, `/NM`,
    /// contents, flags, author, creation date and unknown custom keys. The
    /// subtype-specific `/AP` appearance and `/Subtype` are deliberately not
    /// copied: PDFKit must generate an appearance for the new subtype. The
    /// caller replaces the old annotation in one undoable edit.
    static func replacement(
        for annotation: PDFAnnotation,
        as kind: MarkupKind
    ) throws -> PDFAnnotation {
        guard let page = annotation.page, let document = page.document else {
            throw Failure.annotationNotInDocument
        }
        guard MarkupPermissions.canModify(annotation, in: document, on: page) else {
            throw Failure.annotationIsProtected
        }
        guard MarkupGeometry.quadRects(for: annotation).allSatisfy({ isUsable($0) }) else {
            throw Failure.invalidGeometry
        }

        let replacement = PDFAnnotation(
            bounds: annotation.bounds,
            forType: kind.annotationSubtype,
            withProperties: nil
        )
        replacement.quadrilateralPoints = annotation.quadrilateralPoints
        replacement.color = MarkupColorPalette.annotationColor(
            annotation.color,
            for: kind
        )

        let excluded: Set<String> = [
            "/AP", "/AS", "/Subtype", "/Rect", "/QuadPoints", "/C",
            "/H", "/CA", "/M", "/P", "/Popup", "/Parent"
        ]
        for (rawKey, value) in annotation.annotationKeyValues {
            let key: PDFAnnotationKey
            if let typed = rawKey as? PDFAnnotationKey {
                key = typed
            } else {
                key = PDFAnnotationKey(rawValue: String(describing: rawKey))
            }
            guard !excluded.contains(key.rawValue) else { continue }
            guard !(value is NSNull) else { continue }
            // setValue returns false for keys that are not compatible with the
            // new subtype. That is a signal to skip, not a reason to abort the
            // conversion: the standard metadata above has already been copied.
            _ = replacement.setValue(value, forAnnotationKey: key)
        }

        // A missing /F entry means the booleans are the only display state.
        if annotation.value(forAnnotationKey: .flags) == nil {
            replacement.shouldDisplay = annotation.shouldDisplay
            replacement.shouldPrint = annotation.shouldPrint
        }
        replacement.modificationDate = Date()
        return replacement
    }

    // MARK: - Geometry

    private struct PageQuads {
        let page: PDFPage
        let index: Int
        var rects: [CGRect]
    }

    /// Groups the selection's line rectangles by the page they belong to.
    ///
    /// `selectionsByLine()` returns one selection per line, and for a cross-page
    /// drag each of those lines belongs to exactly one page. Asking every line
    /// for its bounds on every page would be wrong twice: a page the line does
    /// not touch reports a degenerate rectangle, and annotating that page would
    /// put the mark on the wrong sheet. So the page comes from the line itself,
    /// and is then checked against the document.
    private static func pageGroups(
        for selection: PDFSelection,
        in document: PDFDocument
    ) throws -> [PageQuads] {
        var groups: [PageQuads] = []

        for line in selection.selectionsByLine() {
            for page in line.pages {
                let index = document.index(for: page)
                guard index >= 0 else { continue }
                let rect = line.bounds(for: page)
                guard isUsable(rect) else { continue }

                if let existing = groups.firstIndex(where: { $0.page === page }) {
                    groups[existing].rects.append(rect)
                } else {
                    groups.append(PageQuads(page: page, index: index, rects: [rect]))
                }
            }
        }

        guard !groups.isEmpty else { throw Failure.invalidGeometry }
        groups.sort { $0.index < $1.index }
        return groups
    }

    /// Rejects the rectangles PDFKit returns for "this line is not on this
    /// page": zero-sized, or with an infinite origin.
    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }

    /// Quad points in annotation space, in the 'Z' order the PDF specification
    /// asks for: upper-left, upper-right, lower-left, lower-right.
    ///
    /// `PDFAnnotation.quadrilateralPoints` is documented as relative to the
    /// annotation's bounds origin, while `PDFSelection.bounds(for:)` is in page
    /// space — so every point is translated. PDFKit converts them back to page
    /// space when it serialises `/QuadPoints`, which is what other readers read.
    static func quadPoints(for rects: [CGRect], relativeTo origin: CGPoint) -> [NSValue] {
        var points: [NSValue] = []
        points.reserveCapacity(rects.count * 4)
        for rect in rects {
            let minX = rect.minX - origin.x
            let maxX = rect.maxX - origin.x
            let minY = rect.minY - origin.y
            let maxY = rect.maxY - origin.y
            points.append(NSValue(point: CGPoint(x: minX, y: maxY)))
            points.append(NSValue(point: CGPoint(x: maxX, y: maxY)))
            points.append(NSValue(point: CGPoint(x: minX, y: minY)))
            points.append(NSValue(point: CGPoint(x: maxX, y: minY)))
        }
        return points
    }
}

extension HighlightService.Failure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noSelectableText:
            return "Select some text first."
        case .invalidGeometry:
            return "That selection has no text to mark up."
        case .annotationNotInDocument:
            return "That annotation is no longer in this document."
        case .annotationIsProtected:
            return "This annotation is protected and cannot be changed."
        }
    }
}
