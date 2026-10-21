import AppKit
import PDFKit
import SwiftUI
import YoPDFCore

/// Everything a context-menu builder needs to know about the click.
///
/// The menu is built per click rather than cached: the note under the pointer and
/// the anchor for a popover both depend on where the user right-clicked.
struct PageMenuContext {
    let page: PDFPage
    /// The click in page space.
    let pagePoint: CGPoint
    /// The note marker under the pointer, if any.
    let note: NoteSelection?
    /// Where a popover about this click should point, in the reader's
    /// top-left-origin coordinate space.
    let anchorRect: CGRect
}

/// Bridges PDFView into SwiftUI.
///
/// The wrapper owns no reader state: page index, zoom, annotation selection and
/// the note markers live in `PDFDocumentModel`, and the coordinator only reports
/// what PDFView did. The text selection is written back through a binding
/// because the model needs it to decide whether a markup is possible — and
/// because clearing it from the model must clear it in the view.
struct PDFViewerRepresentable: NSViewRepresentable {

    let document: PDFDocument?
    @Binding var currentPageIndex: Int
    @Binding var selection: PDFSelection?
    let autoScales: Bool
    let zoomScale: CGFloat
    let onScaleChange: (CGFloat) -> Void
    let selectedMarkup: MarkupSelection?
    let noteMarkers: [NoteMarker]
    /// While true, the next click on a page places a page note instead of
    /// starting a text selection.
    let isPlacingNote: Bool
    let annotationRevision: Int
    let changedAnnotationPageIndices: [Int]
    let onMarkupClick: (CGPoint, PDFPage) -> Bool
    let onNoteHit: (CGPoint, PDFPage) -> NoteSelection?
    /// A note marker was clicked. The rectangle is in the reader's
    /// top-left-origin space, ready to anchor a popover.
    let onNoteActivated: (NoteSelection, CGRect) -> Void
    let onPlaceNote: (CGPoint, PDFPage, CGRect) -> Void
    let onCancelPlacement: () -> Void
    let makeMenuItems: (PageMenuContext) -> [NSMenuItem]
    /// Lets the SwiftUI layer turn a page rectangle into an anchor rectangle.
    let anchorResolver: PageAnchorResolver

    func makeNSView(context: Context) -> MarkupPDFView {
        let view = MarkupPDFView(frame: .zero)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.backgroundColor = .windowBackgroundColor
        view.selectedMarkup = selectedMarkup
        view.noteMarkers = noteMarkers
        view.isPlacingNote = isPlacingNote
        context.coordinator.attach(to: view)
        context.coordinator.updateHandlers(on: view, parent: self)
        anchorResolver.pdfView = view
        return view
    }

    func updateNSView(_ view: MarkupPDFView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateHandlers(on: view, parent: self)
        anchorResolver.pdfView = view

        if view.document !== document {
            view.clearOverlayViews()
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
        }

        if view.noteMarkers != noteMarkers {
            view.noteMarkers = noteMarkers
        }

        if view.isPlacingNote != isPlacingNote {
            view.isPlacingNote = isPlacingNote
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
        private weak var pdfView: MarkupPDFView?

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
            view.onNoteHit = { [weak self] point, page in
                self?.parent.onNoteHit(point, page)
            }
            view.onNoteActivated = { [weak self] note, rect in
                self?.parent.onNoteActivated(note, rect)
            }
            view.onPlaceNote = { [weak self] point, page, rect in
                self?.parent.onPlaceNote(point, page, rect)
            }
            view.onCancelPlacement = { [weak self] in
                self?.parent.onCancelPlacement()
            }
            view.makeMenuItems = { [weak self] context in
                self?.parent.makeMenuItems(context) ?? []
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

/// Turns a page rectangle into the coordinate space SwiftUI lays out in.
///
/// `PDFView` is not flipped, so its rectangles have a bottom-left origin while
/// the SwiftUI container they are drawn in has a top-left origin. The resolver
/// owns that conversion so the popover anchor and the click handlers cannot
/// disagree about it.
@MainActor
final class PageAnchorResolver {
    weak var pdfView: MarkupPDFView?

    func containerRect(forPageBounds bounds: CGRect, pageIndex: Int) -> CGRect? {
        guard let pdfView,
              let document = pdfView.document,
              let page = document.page(at: pageIndex)
        else { return nil }
        return pdfView.containerRect(forPageRect: bounds, on: page)
    }
}

/// A PDFView that can select a markup, draw note markers and place a page note.
///
/// PDFKit already owns text selection, so the click path runs after
/// `super.mouseUp` and only for a click that did not drag. A click therefore
/// keeps selecting text as before; a click that lands on an existing note opens
/// that note, and a click on a mark selects the mark instead. Right-click reuses
/// the same hit tests and merges the note and markup actions into PDFKit's
/// existing context menu instead of replacing it.
@MainActor
final class MarkupPDFView: PDFView, @MainActor PDFPageOverlayViewProvider {

    var selectedMarkup: MarkupSelection? {
        didSet {
            guard selectedMarkup != oldValue else { return }
            refreshOverlayViews()
        }
    }
    var noteMarkers: [NoteMarker] = [] {
        didSet {
            guard noteMarkers != oldValue else { return }
            refreshOverlayViews()
        }
    }
    var isPlacingNote = false {
        didSet {
            guard isPlacingNote != oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }
    var onMarkupClick: ((CGPoint, PDFPage) -> Bool)?
    var onNoteHit: ((CGPoint, PDFPage) -> NoteSelection?)?
    var onNoteActivated: ((NoteSelection, CGRect) -> Void)?
    var onPlaceNote: ((CGPoint, PDFPage, CGRect) -> Void)?
    var onCancelPlacement: (() -> Void)?
    var makeMenuItems: ((PageMenuContext) -> [NSMenuItem])?

    private var mouseDownPoint: CGPoint?
    private var mouseDidDrag = false
    private var consumedMouseDown = false
    private var overlayViews: [ObjectIdentifier: MarkupSelectionOverlayView] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // This must be installed before a document is assigned. PDFKit asks for
        // page overlays while it builds the page view hierarchy.
        pageOverlayViewProvider = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        pageOverlayViewProvider = self
    }

    /// Drop references to overlays belonging to the previous document. PDFKit
    /// removes the views themselves when the page views go away.
    func clearOverlayViews() {
        overlayViews.removeAll()
    }

    /// A page rectangle in the top-left-origin space the SwiftUI container uses.
    func containerRect(forPageRect rect: CGRect, on page: PDFPage) -> CGRect {
        let inView = convert(rect, from: page)
        guard !isFlipped else { return inView }
        return CGRect(
            x: inView.minX,
            y: bounds.height - inView.maxY,
            width: inView.width,
            height: inView.height
        )
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isPlacingNote {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        if isPlacingNote, let page = page(for: location, nearest: false) {
            // Consumed rather than forwarded: starting PDFKit's own tracking
            // here would begin a text selection under the crosshair.
            consumedMouseDown = true
            let pagePoint = convert(location, to: page)
            let marker = NoteService.markerBounds(
                center: pagePoint,
                in: page.bounds(for: displayBox)
            )
            onPlaceNote?(pagePoint, page, containerRect(forPageRect: marker, on: page))
            return
        }

        mouseDownPoint = location
        mouseDidDrag = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        mouseDidDrag = true
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if consumedMouseDown {
            consumedMouseDown = false
            return
        }

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

        let pagePoint = convert(up, to: page)
        // Notes first: a marker is small, sits above the page and is drawn over
        // any markup beneath it, so a click inside one is a request to open it.
        if let note = onNoteHit?(pagePoint, page) {
            onNoteActivated?(note, containerRect(forPageRect: note.bounds, on: page))
            return
        }
        _ = onMarkupClick?(pagePoint, page)
    }

    override func cancelOperation(_ sender: Any?) {
        if isPlacingNote {
            onCancelPlacement?()
            return
        }
        super.cancelOperation(sender)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let base = super.menu(for: event)
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false) else { return base }

        let pagePoint = convert(point, to: page)
        // Selection side effects first: the menu items read the selected mark.
        _ = onMarkupClick?(pagePoint, page)
        let note = onNoteHit?(pagePoint, page)
        let anchor = note.map { containerRect(forPageRect: $0.bounds, on: page) }
            ?? containerRect(
                forPageRect: NoteService.markerBounds(
                    center: pagePoint,
                    in: page.bounds(for: displayBox)
                ),
                on: page
            )

        let items = makeMenuItems?(
            PageMenuContext(
                page: page,
                pagePoint: pagePoint,
                note: note,
                anchorRect: anchor
            )
        ) ?? []
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

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        let overlay = MarkupSelectionOverlayView()
        let pageIndex = view.document?.index(for: page) ?? -1
        overlay.pageIndex = pageIndex
        overlay.pageBounds = page.bounds(for: view.displayBox)
        overlay.selectedMarkup = selectedMarkup
        overlay.markers = noteMarkers.filter { $0.pageIndex == pageIndex }
        overlayViews[ObjectIdentifier(page)] = overlay
        return overlay
    }

    func pdfView(
        _ pdfView: PDFView,
        willEndDisplayingOverlayView overlayView: NSView,
        for page: PDFPage
    ) {
        overlayViews.removeValue(forKey: ObjectIdentifier(page))
    }

    private func refreshOverlayViews() {
        for overlay in overlayViews.values {
            overlay.selectedMarkup = selectedMarkup
            overlay.markers = noteMarkers.filter { $0.pageIndex == overlay.pageIndex }
        }
    }
}

/// Draws the selected markup outline and the note markers in page coordinates.
///
/// Neither may be implemented in `PDFView.drawPagePost`: PDFKit calls that hook
/// from its tiled-rendering queue, and overriding it on a main-actor `PDFView`
/// subclass traps the process with an executor-isolation assertion. A page
/// overlay is PDFKit's supported hook for content that sits above a page and is
/// automatically resized and rotated with it.
@MainActor
private final class MarkupSelectionOverlayView: NSView {

    var pageIndex = -1
    var pageBounds: CGRect = .zero
    var selectedMarkup: MarkupSelection? {
        didSet { needsDisplay = true }
    }
    var markers: [NoteMarker] = [] {
        didSet {
            guard markers != oldValue else { return }
            needsDisplay = true
        }
    }

    override var isOpaque: Bool { false }

    /// The overlay is presentation-only; clicks must continue to reach the
    /// PDFView beneath it for text selection and note/markup hit-testing.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        drawSelectedMarkup()
        drawNoteMarkers()
    }

    private func drawSelectedMarkup() {
        guard let selectedMarkup, selectedMarkup.pageIndex == pageIndex else { return }

        let accent = NSColor.controlAccentColor
        for rect in selectedMarkup.quadRects {
            let pageRect = rect.offsetBy(dx: -pageBounds.minX, dy: -pageBounds.minY)
            let drawRect = pageRect.insetBy(dx: -1.5, dy: -1.5)
            guard drawRect.width > 0, drawRect.height > 0 else { continue }

            let path = NSBezierPath(roundedRect: drawRect, xRadius: 2, yRadius: 2)

            accent.withAlphaComponent(0.12).setFill()
            path.fill()

            accent.withAlphaComponent(0.95).setStroke()
            path.lineWidth = 1.5
            path.setLineDash([4, 2], count: 2, phase: 0)
            path.stroke()
        }
    }

    /// A small paper-coloured marker with two ruled lines.
    ///
    /// It is drawn slightly larger than the annotation's rectangle and filled
    /// opaquely on purpose: PDFKit renders its own icon for a `/Text`
    /// annotation, and this covers it so the page shows one marker rather than
    /// two. The marker is presentation only — nothing about it is written to the
    /// file, so another reader still sees a standard note icon.
    private func drawNoteMarkers() {
        for marker in markers where marker.pageIndex == pageIndex {
            let rect = marker.bounds.offsetBy(dx: -pageBounds.minX, dy: -pageBounds.minY)
            guard rect.width > 1, rect.height > 1 else { continue }

            let outer = rect.insetBy(dx: -2, dy: -2)
            let paper = marker.paperColor.color

            let body = NSBezierPath(roundedRect: outer, xRadius: 6, yRadius: 6)
            paper.setFill()
            body.fill()
            // Stroking in the fill colour closes the rounded corners so the
            // annotation icon underneath cannot peek through them.
            paper.setStroke()
            body.lineWidth = 2
            body.stroke()

            let border = NSBezierPath(
                roundedRect: outer.insetBy(dx: 0.5, dy: 0.5),
                xRadius: 5.5,
                yRadius: 5.5
            )
            NSColor.black.withAlphaComponent(0.18).setStroke()
            border.lineWidth = 1
            border.stroke()

            drawRuledLines(in: outer)
        }
    }

    private func drawRuledLines(in rect: CGRect) {
        let ink = NSColor(calibratedRed: 0.32, green: 0.26, blue: 0.16, alpha: 0.55)
        ink.setFill()
        let inset = rect.width * 0.24
        let lineHeight = max(rect.height * 0.09, 1)
        let widths: [CGFloat] = [1, 0.72]
        for (index, factor) in widths.enumerated() {
            let y = rect.minY + rect.height * (0.60 - CGFloat(index) * 0.20)
            let width = (rect.width - inset * 2) * factor
            let line = NSBezierPath(
                roundedRect: CGRect(
                    x: rect.minX + inset,
                    y: y,
                    width: max(width, 1),
                    height: lineHeight
                ),
                xRadius: lineHeight / 2,
                yRadius: lineHeight / 2
            )
            line.fill()
        }
    }
}
