import CoreGraphics

/// Pure decisions used by the `PDFView` bridge.
///
/// They live in `YoPDFCore` (no AppKit) so the page/zoom synchronisation rules
/// can be tested without a window server. The bridge still owns the actual
/// `PDFView` calls; this only decides *what* to apply.
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
