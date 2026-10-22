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
    private var pendingNoteActivation: (NoteSelection, CGRect)?
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
                in: page.bounds(for: .cropBox)
            )
            onPlaceNote?(pagePoint, page, containerRect(forPageRect: marker, on: page))
            return
        }

        if let page = page(for: location, nearest: false) {
            let pagePoint = convert(location, to: page)
            if let note = onNoteHit?(pagePoint, page), note.isYoPDFNote {
                consumedMouseDown = true
                pendingNoteActivation = (note, containerRect(forPageRect: note.bounds, on: page))
                mouseDownPoint = location
                mouseDidDrag = false
                return
            }
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
            if let pendingNoteActivation {
                onNoteActivated?(pendingNoteActivation.0, pendingNoteActivation.1)
            }
            pendingNoteActivation = nil
            mouseDownPoint = nil
            mouseDidDrag = false
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
                    in: page.bounds(for: .cropBox)
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
        overlay.page = page
        overlay.pageBounds = page.bounds(for: .cropBox)
        overlay.selectedMarkup = selectedMarkup
        overlay.markers = noteMarkers.filter { $0.pageIndex == pageIndex }
        overlay.onMarkerActivated = { [weak self] marker in
            guard let self,
                  let page = self.document?.page(at: marker.pageIndex),
                  let note = self.onNoteHit?(marker.center, page)
            else { return }
            self.onNoteActivated?(
                note,
                self.containerRect(forPageRect: note.bounds, on: page)
            )
        }
        overlay.onMarkerMenu = { [weak self] marker in
            guard let self,
                  let page = self.document?.page(at: marker.pageIndex)
            else { return nil }
            let note = self.onNoteHit?(marker.center, page)
            let anchor = note.map { self.containerRect(forPageRect: $0.bounds, on: page) }
                ?? self.containerRect(forPageRect: marker.bounds, on: page)
            let items = self.makeMenuItems?(
                PageMenuContext(
                    page: page,
                    pagePoint: marker.center,
                    note: note,
                    anchorRect: anchor
                )
            ) ?? []
            guard !items.isEmpty else { return nil }
            let menu = NSMenu()
            for item in items {
                menu.addItem(item)
            }
            return menu
        }
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
    var page: PDFPage?
    var pageBounds: CGRect = .zero
    var selectedMarkup: MarkupSelection? {
        didSet { needsDisplay = true }
    }
    var markers: [NoteMarker] = [] {
        didSet {
            guard markers != oldValue else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var onMarkerActivated: ((NoteMarker) -> Void)?
    var onMarkerMenu: ((NoteMarker) -> NSMenu?)?

    override var isOpaque: Bool { false }

    private func marker(at point: NSPoint) -> NoteMarker? {
        let pagePoint = CGPoint(
            x: point.x + pageBounds.minX,
            y: point.y + pageBounds.minY
        )
        return markers.reversed().first {
            stickerFrame(for: $0.bounds).contains(pagePoint)
        }
    }

    /// Markers take clicks so PDFKit cannot open its native note popup over the
    /// sticker. Everywhere else the overlay is transparent to hit testing, so
    /// text selection, links and scrolling keep working.
    override func hitTest(_ point: NSPoint) -> NSView? {
        marker(at: point) == nil ? nil : self
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for marker in markers {
            let frame = stickerFrame(for: marker.bounds)
            let rect = frame.offsetBy(dx: -pageBounds.minX, dy: -pageBounds.minY)
            addCursorRect(rect, cursor: .pointingHand)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let marker = self.marker(at: point) else { return }
        onMarkerActivated?(marker)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let marker = self.marker(at: point) else { return nil }
        return onMarkerMenu?(marker)
    }

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

    /// Draws the ShuaMac marker treatment: the original 32pt artwork with its
    /// subtle shadow, or a colored rounded-square fallback with a brown symbol.
    ///
    /// PDFKit still renders its native note icon underneath. The page content
    /// is re-drawn with YoPDF's annotations removed inside each marker's small
    /// rect, exactly like ShuaMac's page overlay, so the transparent parts of a
    /// sticker cannot reveal a second icon. There is deliberately no card,
    /// stacked border or palette fill here.
    private func drawNoteMarkers() {
        guard let page else { return }

        for marker in markers where marker.pageIndex == pageIndex {
            let rect = marker.bounds.offsetBy(dx: -pageBounds.minX, dy: -pageBounds.minY)
            guard rect.width > 1, rect.height > 1 else { continue }
            drawPageBackground(in: rect, page: page)
            drawSticker(marker.style, at: rect)
        }
    }

    /// Masks PDFKit's built-in note icon by reproducing the page without this
    /// application's note annotations inside the marker rectangle only. The rest
    /// of PDFKit's rendering, text selection and links stay untouched.
    private func drawPageBackground(in rect: CGRect, page: PDFPage) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let pageCopy = page.copy() as? PDFPage
        else { return }

        pageCopy.rotation = 0
        pageCopy.displaysAnnotations = page.displaysAnnotations
        for annotation in pageCopy.annotations {
            if NoteService.isYoPDFNote(annotation) || annotation.type == "Popup" {
                pageCopy.removeAnnotation(annotation)
            }
        }

        let crop = pageCopy.bounds(for: .cropBox)
        guard crop.width > 0, crop.height > 0, bounds.width > 0, bounds.height > 0 else {
            return
        }

        let scale = min(bounds.width / crop.width, bounds.height / crop.height)
        let renderedSize = CGSize(
            width: crop.width * scale,
            height: crop.height * scale
        )

        context.saveGState()
        context.clip(to: rect)
        context.translateBy(
            x: bounds.midX - renderedSize.width / 2 - crop.minX * scale,
            y: bounds.midY - renderedSize.height / 2 - crop.minY * scale
        )
        context.scaleBy(x: scale, y: scale)
        pageCopy.draw(with: .cropBox, to: context)
        context.restoreGState()
    }

    /// The size of ShuaMac's sticker artwork inside a marker.
    private static let stickerArtworkSize: CGFloat = 32

    /// The marker frame: exactly the sticker artwork.
    ///
    /// ShuaMac grows its overlay frame sideways for a multi-thought count badge.
    /// A YoPDF note holds exactly one body, so there is no count to show and no
    /// badge to reserve room for; the marker is the 32pt face itself.
    private static var stickerSize: CGSize {
        CGSize(width: stickerArtworkSize, height: stickerArtworkSize)
    }

    /// The marker frame centred on a note's anchor, clamped to the page.
    ///
    /// ShuaMac centres the frame on the anchor point and then clamps it inside the
    /// overlay, so a marker near a page edge cannot push its artwork out of view.
    /// YoPDF stores a 24pt `/Rect` rather than a point, so the frame is centred on
    /// that rect and clamped to the same page area.
    private func stickerFrame(for anchorRect: CGRect) -> CGRect {
        let size = Self.stickerSize
        let proposed = CGRect(
            x: anchorRect.midX - size.width / 2,
            y: anchorRect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        guard pageBounds.width > 0, pageBounds.height > 0 else { return proposed }

        let minimumX = pageBounds.minX + 2
        let minimumY = pageBounds.minY + 2
        let maximumX = max(minimumX, pageBounds.maxX - size.width - 2)
        let maximumY = max(minimumY, pageBounds.maxY - size.height - 2)
        return CGRect(
            x: min(max(proposed.minX, minimumX), maximumX),
            y: min(max(proposed.minY, minimumY), maximumY),
            width: size.width,
            height: size.height
        )
    }

    private func drawSticker(_ style: NoteStickerStyle, at anchor: CGRect) {
        let artRect = stickerFrame(for: anchor)

        if let name = style.motif.assetName,
           let image = NSImage(named: NSImage.Name(name)) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.imageInterpolation = .high
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.13)
            shadow.shadowBlurRadius = 1.5
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            image.draw(in: artRect, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            style.palette.color.setFill()
            NSBezierPath(
                roundedRect: artRect.insetBy(dx: 3, dy: 3),
                xRadius: 6,
                yRadius: 6
            ).fill()
            let icon = NSImage(
                systemSymbolName: style.resolvedSymbol,
                accessibilityDescription: nil
            )?.withSymbolConfiguration(.init(paletteColors: [.brown]))
            icon?.draw(in: artRect.insetBy(dx: 8, dy: 8))
        }
    }

}
