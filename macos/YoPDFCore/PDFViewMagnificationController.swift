import AppKit
import PDFKit

/// Observes trackpad magnification before PDFKit receives it, only to leave Fit
/// mode once at the start of a gesture. The original event is always forwarded
/// unchanged so PDFKit's native scroll-view path owns live zoom, anchoring and
/// page rendering.
@MainActor
public final class PDFViewMagnificationController {
    public var onManualMagnification: (() -> Void)?
    private var monitor: LocalMagnificationMonitor?
    private weak var attachedView: PDFView?
    private var isMagnifying = false

    public init() {}

    public func attach(to view: PDFView) {
        detach()
        guard view.window != nil else { return }
        attachedView = view
        let token = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self, weak view] event in
            // The event is not Sendable, so it must not cross the isolation
            // boundary as a return value: observe it inside the isolated block
            // and forward the original object unchanged from here.
            MainActor.assumeIsolated {
                guard let self, let view else { return }
                self.observeLocalEvent(event, in: view)
            }
            return event
        }
        monitor = token.map(LocalMagnificationMonitor.init)
    }

    public func detach() {
        monitor = nil
        attachedView = nil
        isMagnifying = false
    }

    /// This is an observe-only monitor. Forwarding the same event is important:
    /// PDFKit's internal NSScrollView performs the continuous magnification and
    /// its temporary live transform without forcing a PDFView layout/raster
    /// update for every trackpad delta.
    private func observeLocalEvent(_ event: NSEvent, in view: PDFView) {
        guard let window = view.window,
              event.window === window,
              view.document != nil
        else { return }

        let point = view.convert(event.locationInWindow, from: nil)
        guard isMagnifying || view.bounds.contains(point) else { return }

        if event.phase.contains(.cancelled) {
            isMagnifying = false
            return
        }

        let gestureIsActive = event.phase.contains(.began)
            || event.phase.contains(.changed)
            || event.magnification != 0

        if gestureIsActive, !isMagnifying {
            isMagnifying = true
            if view.autoScales {
                // Preserve the fitted scale as the starting point for PDFKit's
                // native gesture, but do not set scaleFactor ourselves.
                view.autoScales = false
                onManualMagnification?()
            }
        }

        if event.phase.contains(.ended) {
            isMagnifying = false
        }
    }
}

/// The token removes itself even if a window is torn down without another
/// representable update. NSEvent holds only weak references to the reader.
private final class LocalMagnificationMonitor {
    let token: Any
    init(_ token: Any) { self.token = token }
    deinit { NSEvent.removeMonitor(token) }
}
