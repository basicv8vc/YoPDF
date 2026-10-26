import AppKit
import PDFKit

/// Commits trackpad magnification to PDFKit's persistent scale, rather than its
/// scroll view's temporary gesture transform. The monitor runs before PDFKit's
/// internal child views receive the event and consumes only this reader's pinch.
@MainActor
public final class PDFViewMagnificationController {
    public var onScaleChanged: ((CGFloat) -> Void)?
    private var monitor: LocalMagnificationMonitor?
    private weak var attachedView: PDFView?
    private var isMagnifying = false

    public init() {}

    public func attach(to view: PDFView) {
        detach()
        guard view.window != nil else { return }
        attachedView = view
        let token = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self, weak view] event in
            var handled = false
            MainActor.assumeIsolated {
                if let self, let view {
                    handled = self.handleLocalEvent(event, in: view)
                }
            }
            return handled ? nil : event
        }
        monitor = token.map(LocalMagnificationMonitor.init)
    }

    public func detach() {
        monitor = nil
        attachedView = nil
        isMagnifying = false
    }

    private func handleLocalEvent(_ event: NSEvent, in view: PDFView) -> Bool {
        guard let window = view.window, event.window === window, view.document != nil else { return false }
        let point = view.convert(event.locationInWindow, from: nil)
        guard isMagnifying || view.bounds.contains(point) else { return false }
        isMagnifying = !event.phase.contains(.ended) && !event.phase.contains(.cancelled)
        magnify(with: event, in: view)
        return true
    }

    /// Shared by the event monitor, the PDFView responder fallback, and tests.
    /// Events contain incremental magnification, including a possible final
    /// delta in the ended phase. Cancellation keeps the last committed scale.
    public func magnify(with event: NSEvent, in view: PDFView) {
        guard event.type == .magnify, view.document != nil,
              !event.phase.contains(.cancelled),
              event.magnification.isFinite, event.magnification > -1,
              view.scaleFactor.isFinite, view.scaleFactor > 0 else { return }

        let point = view.convert(event.locationInWindow, from: nil)
        let page = view.page(for: point, nearest: true)
        let anchor = page.map { view.convert(point, to: $0) }
        let scale = min(max(view.scaleFactor * (1 + event.magnification),
                            PDFDocumentModel.minimumZoomScale), PDFDocumentModel.maximumZoomScale)
        view.autoScales = false
        if ReaderViewSync.shouldApplyZoom(current: view.scaleFactor, target: scale, tolerance: 0) {
            view.scaleFactor = scale
            // Keep the page point under the fingers in the same viewport
            // position. Convert through the document view to respect flipped
            // clip views, rotated pages and horizontal scrolling.
            if let page, let anchor, let documentView = view.documentView,
               let scrollView = documentView.enclosingScrollView {
                let after = documentView.convert(view.convert(anchor, from: page), from: view)
                let before = documentView.convert(point, from: view)
                let clipView = scrollView.contentView
                var bounds = clipView.bounds
                bounds.origin.x += after.x - before.x
                bounds.origin.y += after.y - before.y
                clipView.scroll(to: clipView.constrainBoundsRect(bounds).origin)
                scrollView.reflectScrolledClipView(clipView)
            }
        }
        onScaleChanged?(view.scaleFactor)
    }
}

/// The token removes itself even if a window is torn down without another
/// representable update. NSEvent holds only weak references to the reader.
private final class LocalMagnificationMonitor {
    let token: Any
    init(_ token: Any) { self.token = token }
    deinit { NSEvent.removeMonitor(token) }
}
