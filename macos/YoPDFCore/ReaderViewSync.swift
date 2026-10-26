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

/// Applies explicit reader commands without replaying state mirrored from native
/// scrolling or magnification. A document replacement restores the viewport in
/// the replacement's page objects, while intermediate PDFKit notifications are
/// excluded from model feedback by `isApplyingUpdate`.
@MainActor
public final class PDFViewStateSynchronizer {

    private var lastAppliedZoomCommandRevision: Int?
    private var lastAppliedPageNavigationRevision: Int?
    public private(set) var isApplyingUpdate = false

    public init() {}

    public func update(
        pdfView: PDFView,
        document: PDFDocument?,
        currentPageIndex: Int,
        pageNavigationRevision: Int,
        autoScales: Bool,
        zoomScale: CGFloat,
        zoomCommandRevision: Int
    ) {
        let documentChanged = pdfView.document !== document
        let pageCommandChanged = lastAppliedPageNavigationRevision != pageNavigationRevision
        let zoomCommandChanged = lastAppliedZoomCommandRevision != zoomCommandRevision

        // The same PDFView survives Save / Save As. Capture its page-space
        // viewport before assignment resets PDFKit to the beginning. A pending
        // navigation command takes precedence over that previous viewport.
        let previousDestination = documentChanged && !pageCommandChanged
            ? pdfView.currentDestination : nil
        let previousPageIndex = previousDestination?.page.flatMap { page in
            pdfView.document?.index(for: page)
        }

        isApplyingUpdate = true
        defer { isApplyingUpdate = false }

        if documentChanged {
            pdfView.document = document
        }

        if documentChanged || zoomCommandChanged {
            pdfView.autoScales = autoScales
            if !autoScales {
                pdfView.scaleFactor = zoomScale
            }
        }
        lastAppliedZoomCommandRevision = zoomCommandRevision
        lastAppliedPageNavigationRevision = pageNavigationRevision

        guard documentChanged || pageCommandChanged,
              let document,
              let index = ReaderViewSync.clampedPageIndex(currentPageIndex, pageCount: document.pageCount),
              let page = document.page(at: index)
        else { return }

        if let previousDestination, let previousPageIndex,
           previousPageIndex >= 0, previousPageIndex < document.pageCount,
           let previousPage = document.page(at: previousPageIndex) {
            let destination = PDFDestination(page: previousPage, at: previousDestination.point)
            destination.zoom = kPDFDestinationUnspecifiedValue
            pdfView.go(to: destination)
        } else {
            pdfView.go(to: page)
        }
    }
}
