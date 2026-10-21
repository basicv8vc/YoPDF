import AppKit
import PDFKit

/// Turns a `PDFSelection` into standard PDF highlight annotations.
///
/// This is the one place where a selection becomes an annotation. It is kept
/// deliberately narrow — one annotation type, one colour, no custom geometry —
/// so that P2b can extend this file instead of adding a second annotation path.
///
/// The output is a plain `/Highlight` annotation with `/QuadPoints`, which is
/// what Preview, Adobe Reader and PDFium understand. Nothing application
/// specific is written, so the result stays interoperable by construction.
@MainActor
public enum HighlightService {

    /// The fixed highlight colour.
    ///
    /// An explicit sRGB value rather than `NSColor.systemYellow`: a dynamic
    /// system colour resolves differently per appearance and would make the
    /// stored `/C` array depend on when the user happened to click. `(1, 0.8, 0)`
    /// is the value PDFKit itself writes for the standard yellow highlight.
    public static let color = NSColor(srgbRed: 1.0, green: 0.8, blue: 0.0, alpha: 1.0)

    public enum Failure: Error, Equatable {
        /// Nothing selectable under the pointer: an image, a margin, a blank
        /// area. Creating an annotation here would produce a zero-area mark.
        case noSelectableText
        /// The selection resolved to no rectangle that could be marked up.
        case invalidGeometry
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

    /// Adds a highlight for `selection` to `document`.
    ///
    /// A selection spanning several pages becomes one annotation per page,
    /// each carrying only the quads that belong to it. A selection that
    /// resolves to no text, or to no usable geometry, throws and leaves the
    /// document untouched.
    @discardableResult
    public static func addHighlight(
        from selection: PDFSelection,
        to document: PDFDocument,
        color: NSColor? = nil
    ) throws -> Summary {
        let text = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.noSelectableText }

        let groups = try pageGroups(for: selection, in: document)
        let resolvedColor = color ?? Self.color

        var quadCount = 0
        for group in groups {
            let bounds = group.rects.dropFirst().reduce(group.rects[0]) { $0.union($1) }
            let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            annotation.color = resolvedColor
            annotation.quadrilateralPoints = quadPoints(for: group.rects, relativeTo: bounds.origin)
            group.page.addAnnotation(annotation)
            quadCount += group.rects.count
        }

        return Summary(
            pageIndices: groups.map(\.index),
            annotationCount: groups.count,
            quadCount: quadCount
        )
    }

    /// The per-line rectangles a highlight would use, grouped by page.
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

    // MARK: - Geometry

    private struct PageQuads {
        let page: PDFPage
        let index: Int
        var rects: [CGRect]
    }

    /// Groups the selection's line rectangles by the page they belong to.
    ///
    /// `selectionsByLine()` returns one selection per line, and for a
    /// cross-page drag each of those lines belongs to exactly one page. Asking
    /// every line for its bounds on every page would be wrong twice: a page the
    /// line does not touch reports a degenerate rectangle, and annotating that
    /// page would put the mark on the wrong sheet. So the page comes from the
    /// line itself, and is then checked against the document.
    private static func pageGroups(
        for selection: PDFSelection,
        in document: PDFDocument
    ) throws -> [PageQuads] {
        var groups: [PageQuads] = []

        for line in selection.selectionsByLine() {
            for page in line.pages {
                let index = document.index(for: page)
                // A page that is not part of this document is never annotated,
                // even if the selection somehow references it.
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
            return "That selection has no text to highlight."
        }
    }
}
