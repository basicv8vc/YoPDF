import CoreGraphics
import PDFKit

/// Pure value decisions used by the `PDFView` bridge.
public enum ReaderViewSync {

    /// Page index to show, clamped to the document. `nil` when there is nothing
    /// to show (empty document).
    public static func clampedPageIndex(_ index: Int, pageCount: Int) -> Int? {
        guard pageCount > 0 else { return nil }
        return min(max(index, 0), pageCount - 1)
    }

    /// Whether a scale reported by the view differs enough from the requested
    /// scale to be written back. Avoids feedback loops from float noise.
    public static func shouldApplyZoom(
        current: CGFloat,
        target: CGFloat,
        tolerance: CGFloat = 0.001
    ) -> Bool {
        guard current.isFinite, target.isFinite, target > 0 else { return false }
        return abs(current - target) > tolerance
    }
}

/// Keeps PDFView's native gesture state separate from explicit zoom commands.
/// A document replacement always reapplies the model's current zoom state;
/// ordinary SwiftUI refreshes only apply when the user issued a new command.
@MainActor
public final class PDFViewZoomSynchronizer {

    private var lastAppliedZoomCommandRevision: Int?

    public init() {}

    public func update(
        pdfView: PDFView,
        document: PDFDocument?,
        autoScales: Bool,
        zoomScale: CGFloat,
        zoomCommandRevision: Int
    ) {
        let documentChanged = pdfView.document !== document
        if documentChanged {
            pdfView.document = document
        }

        guard documentChanged || lastAppliedZoomCommandRevision != zoomCommandRevision else {
            return
        }

        pdfView.autoScales = autoScales
        if !autoScales {
            pdfView.scaleFactor = zoomScale
        }
        lastAppliedZoomCommandRevision = zoomCommandRevision
    }
}
