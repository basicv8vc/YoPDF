import AppKit
import PDFKit
import SwiftUI
import YoPDFCore

/// Bridges PDFView into SwiftUI.
///
/// The wrapper owns no reader state: page index, zoom and annotation selection
/// live in `PDFDocumentModel`, and the coordinator only reports what PDFView did.
/// The text selection is written back through a binding because the model needs
/// it to decide whether a markup is possible — and because clearing it from the
/// model must clear it in the view.
struct PDFViewerRepresentable: NSViewRepresentable {

    let document: PDFDocument?
    @Binding var currentPageIndex: Int
    @Binding var selection: PDFSelection?
    let autoScales: Bool
    let zoomScale: CGFloat
    let onScaleChange: (CGFloat) -> Void
    let selectedMarkup: MarkupSelection?
    let annotationRevision: Int
    let changedAnnotationPageIndices: [Int]
    let onMarkupClick: (CGPoint, PDFPage) -> Bool
    let makeMarkupMenuItems: () -> [NSMenuItem]

    func makeNSView(context: Context) -> MarkupPDFView {
        let view = MarkupPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.backgroundColor = .windowBackgroundColor
        view.selectedMarkup = selectedMarkup
        context.coordinator.attach(to: view)
        context.coordinator.updateHandlers(on: view, parent: self)
        return view
    }

    func updateNSView(_ view: MarkupPDFView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateHandlers(on: view, parent: self)

        if view.document !== document {
            view.document = document
            if document != nil {
                view.autoScales = true
            }
        }

        view.autoScales = autoScales

        if !autoScales,
           ReaderViewSync.shouldApplyZoom(current: view.scaleFactor, target: zoomScale) {
            view.scaleFactor = zoomScale
        }

        // The model cleared the selection: the markup consumed it, or a new
        // document replaced it. PDFView keeps drawing its own selection until
        // told otherwise, so it has to be cleared here rather than in the model.
        if selection == nil, view.currentSelection != nil {
            view.clearSelection()
        }

        if view.selectedMarkup != selectedMarkup {
            view.selectedMarkup = selectedMarkup
            view.needsDisplay = true
            view.documentView?.needsDisplay = true
        }

        if context.coordinator.lastAnnotationRevision != annotationRevision {
            context.coordinator.lastAnnotationRevision = annotationRevision
            for pageIndex in changedAnnotationPageIndices {
                guard let page = document?.page(at: pageIndex) else { continue }
                view.annotationsChanged(on: page)
            }
            view.needsDisplay = true
            view.documentView?.needsDisplay = true
        }

        guard let document,
              let clamped = ReaderViewSync.clampedPageIndex(currentPageIndex, pageCount: document.pageCount)
        else { return }
        if let target = document.page(at: clamped), view.currentPage !== target {
            view.go(to: target)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: PDFViewerRepresentable
        var lastAnnotationRevision = -1
        private weak var pdfView: PDFView?

        init(parent: PDFViewerRepresentable) {
            self.parent = parent
        }

        func attach(to view: MarkupPDFView) {
            pdfView = view
            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(pageDidChange(_:)),
                name: .PDFViewPageChanged,
                object: view
            )
            center.addObserver(
                self,
                selector: #selector(scaleDidChange(_:)),
                name: .PDFViewScaleChanged,
                object: view
            )
            center.addObserver(
                self,
                selector: #selector(selectionDidChange(_:)),
                name: .PDFViewSelectionChanged,
                object: view
            )
        }

        func updateHandlers(on view: MarkupPDFView, parent: PDFViewerRepresentable) {
            view.onMarkupClick = { [weak self] point, page in
                guard let self else { return false }
                return self.parent.onMarkupClick(point, page)
            }
            view.makeMarkupMenuItems = { [weak self] in
                self?.parent.makeMarkupMenuItems() ?? []
            }
        }

        @objc private func pageDidChange(_ notification: Notification) {
            guard let view = pdfView, let page = view.currentPage, let document = view.document else {
                return
            }
            let index = document.index(for: page)
            guard index >= 0, index != parent.currentPageIndex else { return }
            parent.currentPageIndex = index
        }

        @objc private func scaleDidChange(_ notification: Notification) {
            guard let view = pdfView else { return }
            parent.onScaleChange(view.scaleFactor)
        }

        @objc private func selectionDidChange(_ notification: Notification) {
            guard let view = pdfView else { return }
            let current = view.currentSelection
            guard current !== parent.selection else { return }
            parent.selection = current
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

/// A PDFView that can select and outline a markup annotation.
///
/// PDFKit already owns text selection, so the click path runs after
/// `super.mouseUp` and only for a click that did not drag. A click therefore
/// keeps selecting text as before; a click that lands on an existing mark selects
/// that mark instead. Right-click reuses the same model hit test and merges the
/// markup actions into PDFKit's existing context menu instead of replacing it.
@MainActor
final class MarkupPDFView: PDFView {

    var selectedMarkup: MarkupSelection?
    var onMarkupClick: ((CGPoint, PDFPage) -> Bool)?
    var makeMarkupMenuItems: (() -> [NSMenuItem])?

    private var mouseDownPoint: CGPoint?
    private var mouseDidDrag = false

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        mouseDidDrag = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        mouseDidDrag = true
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        defer {
            mouseDownPoint = nil
            mouseDidDrag = false
        }
        guard event.clickCount == 1,
              !mouseDidDrag,
              let down = mouseDownPoint
        else { return }

        let up = convert(event.locationInWindow, from: nil)
        guard hypot(up.x - down.x, up.y - down.y) <= 3,
              let page = page(for: up, nearest: false)
        else { return }
        _ = onMarkupClick?(convert(up, to: page), page)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let base = super.menu(for: event)
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false),
              onMarkupClick?(convert(point, to: page), page) == true
        else { return base }

        let items = makeMarkupMenuItems?() ?? []
        guard !items.isEmpty else { return base }

        if let base {
            base.insertItem(.separator(), at: 0)
            for (index, item) in items.enumerated() {
                base.insertItem(item, at: index)
            }
            return base
        }

        let menu = NSMenu()
        for item in items {
            menu.addItem(item)
        }
        return menu
    }

    override func drawPagePost(_ page: PDFPage, to context: CGContext) {
        super.drawPagePost(page, to: context)
        guard let selectedMarkup,
              let document,
              document.index(for: page) == selectedMarkup.pageIndex
        else { return }

        let accent = NSColor.controlAccentColor
        context.saveGState()
        defer { context.restoreGState() }

        for rect in selectedMarkup.quadRects {
            let viewRect = convert(rect, from: page).insetBy(dx: -1.5, dy: -1.5)
            guard viewRect.width > 0, viewRect.height > 0 else { continue }
            let path = CGPath(
                roundedRect: viewRect,
                cornerWidth: 2,
                cornerHeight: 2,
                transform: nil
            )

            context.addPath(path)
            context.setFillColor(accent.withAlphaComponent(0.12).cgColor)
            context.fillPath()

            context.addPath(path)
            context.setStrokeColor(accent.withAlphaComponent(0.95).cgColor)
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [4, 2])
            context.strokePath()
        }
    }
}
