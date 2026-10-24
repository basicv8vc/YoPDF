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
    let zoomCommandRevision: Int
    let onScaleChange: (CGFloat) -> Void
    let onManualMagnification: () -> Void
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
    /// A sticker was dragged to a new center in PDF page coordinates.
    let onNoteMoved: (NoteSelection, CGPoint) -> Void
    let onPlaceNote: (CGPoint, PDFPage, CGRect) -> Void
    let onCancelPlacement: () -> Void
    let makeMenuItems: (PageMenuContext) -> [NSMenuItem]
    /// Lets the SwiftUI layer turn a page rectangle into an anchor rectangle.
    let anchorResolver: PageAnchorResolver

    func makeNSView(context: Context) -> MarkupPDFView {
        let view = MarkupPDFView(frame: .zero)
        view.autoScales = autoScales
        if !autoScales {
            view.scaleFactor = zoomScale
        }
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
        }

        // Apply after document assignment. Replacements (including Save and
        // Save As) must restore the model's current Fit/manual zoom state.
        // Ordinary scale notifications still avoid writing back into PDFKit's
        // active native gesture.
        context.coordinator.zoomSynchronizer.update(
            pdfView: view,
            document: document,
            autoScales: autoScales,
            zoomScale: zoomScale,
            zoomCommandRevision: zoomCommandRevision
        )

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
        let zoomSynchronizer = PDFViewZoomSynchronizer()
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
            view.onNoteMoved = { [weak self] note, center in
                self?.parent.onNoteMoved(note, center)
            }
            view.onPlaceNote = { [weak self] point, page, rect in
                self?.parent.onPlaceNote(point, page, rect)
            }
            view.onCancelPlacement = { [weak self] in
                self?.parent.onCancelPlacement()
            }
            view.onManualMagnification = { [weak self] in
                self?.parent.onManualMagnification()
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
    var onNoteMoved: ((NoteSelection, CGPoint) -> Void)?
    var onPlaceNote: ((CGPoint, PDFPage, CGRect) -> Void)?
    var onCancelPlacement: (() -> Void)?
    var onManualMagnification: (() -> Void)?
    var makeMenuItems: ((PageMenuContext) -> [NSMenuItem])?

    private var mouseDownPoint: CGPoint?
    private var mouseDidDrag = false
    private var consumedMouseDown = false
    private var pendingNoteActivation: (NoteSelection, CGRect)?
    private struct MarkerDragSession {
        let marker: NoteMarker
        let page: PDFPage
        let startPagePoint: CGPoint
        let startCenter: CGPoint
    }
    private var markerDragSession: MarkerDragSession?
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

    override func magnify(with event: NSEvent) {
        if autoScales {
            // Keep the fitted scale as the starting point for manual zoom, then
            // let PDFKit apply the trackpad gesture with auto-scaling disabled.
            onManualMagnification?()
            autoScales = false
        }
        super.magnify(with: event)
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

        if let marker = noteMarker(at: location),
           let page = document?.page(at: marker.pageIndex) {
            // The PDFView path is a fallback for page overlays whose input
            // hit-testing does not follow PDFKit's rotation transform. Use
            // PDFView's page conversion for both the initial point and drag.
            consumedMouseDown = true
            markerDragSession = MarkerDragSession(
                marker: marker,
                page: page,
                startPagePoint: convert(location, to: page),
                startCenter: CGPoint(x: marker.bounds.midX, y: marker.bounds.midY)
            )
            mouseDownPoint = location
            mouseDidDrag = false
            return
        }

        if let page = page(for: location, nearest: false) {
            let pagePoint = convert(location, to: page)
            if let note = onNoteHit?(pagePoint, page), note.usesStickerPresentation {
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
        if let session = markerDragSession {
            let location = convert(event.locationInWindow, from: nil)
            let pagePoint = convert(location, to: session.page)
            let delta = CGPoint(
                x: pagePoint.x - session.startPagePoint.x,
                y: pagePoint.y - session.startPagePoint.y
            )
            if !mouseDidDrag, hypot(delta.x, delta.y) > 3 {
                mouseDidDrag = true
            }
            guard mouseDidDrag else { return }
            let center = CGPoint(
                x: session.startCenter.x + delta.x,
                y: session.startCenter.y + delta.y
            )
            overlayViews[ObjectIdentifier(session.page)]?.setExternalDragPreview(
                session.marker,
                center: center
            )
            return
        }

        mouseDidDrag = true
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if let session = markerDragSession {
            let location = convert(event.locationInWindow, from: nil)
            let pagePoint = convert(location, to: session.page)
            let delta = CGPoint(
                x: pagePoint.x - session.startPagePoint.x,
                y: pagePoint.y - session.startPagePoint.y
            )
            if !mouseDidDrag, hypot(delta.x, delta.y) > 3 {
                mouseDidDrag = true
            }
            let moved = mouseDidDrag
            let destination = CGPoint(
                x: session.startCenter.x + delta.x,
                y: session.startCenter.y + delta.y
            )
            markerDragSession = nil
            consumedMouseDown = false
            mouseDownPoint = nil
            mouseDidDrag = false
            overlayViews[ObjectIdentifier(session.page)]?.setExternalDragPreview(nil, center: nil)

            if let note = onNoteHit?(session.startCenter, session.page) {
                if moved {
                    onNoteMoved?(note, destination)
                } else {
                    onNoteActivated?(
                        note,
                        containerRect(forPageRect: note.bounds, on: session.page)
                    )
                }
            }
            return
        }

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
        overlay.pagePointForOverlayPoint = { [weak self, weak overlay, weak page] point in
            guard let self, let overlay, let page else { return .zero }
            let pdfViewPoint = self.convert(point, from: overlay)
            return self.convert(pdfViewPoint, to: page)
        }
        overlay.selectedMarkup = selectedMarkup
        overlay.markers = noteMarkers.filter { $0.pageIndex == pageIndex }
        overlay.onMarkerActivated = { [weak self] marker in
            guard let self,
                  let page = self.document?.page(at: marker.pageIndex),
                  let note = self.onNoteHit?(markerDisplayCenter(marker), page)
            else { return }
            self.onNoteActivated?(
                note,
                self.containerRect(forPageRect: note.bounds, on: page)
            )
        }
        overlay.onMarkerMoved = { [weak self] marker, center in
            guard let self,
                  let page = self.document?.page(at: marker.pageIndex),
                  let note = self.onNoteHit?(markerDisplayCenter(marker), page)
            else { return }
            self.onNoteMoved?(note, center)
        }
        overlay.onMarkerMenu = { [weak self] marker in
            guard let self,
                  let page = self.document?.page(at: marker.pageIndex)
            else { return nil }
            let note = self.onNoteHit?(markerDisplayCenter(marker), page)
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

    private func markerDisplayCenter(_ marker: NoteMarker) -> CGPoint {
        CGPoint(x: marker.bounds.midX, y: marker.bounds.midY)
    }

    private func noteMarker(at viewPoint: CGPoint) -> NoteMarker? {
        noteMarkers.reversed().first { marker in
            guard let page = document?.page(at: marker.pageIndex) else { return false }
            return convert(marker.bounds, from: page).contains(viewPoint)
        }
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
    var pagePointForOverlayPoint: ((CGPoint) -> CGPoint)?
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
    var onMarkerMoved: ((NoteMarker, CGPoint) -> Void)?
    var onMarkerMenu: ((NoteMarker) -> NSMenu?)?

    private var pressedMarker: NoteMarker?
    private var dragStartPagePoint: CGPoint?
    private var dragStartCenter: CGPoint?
    private var previewCenter: CGPoint?
    private var didDragMarker = false

    override var isOpaque: Bool { false }

    private func marker(at point: NSPoint) -> NoteMarker? {
        let pagePoint = self.pagePoint(for: point)
        return markers.reversed().first {
            displayedBounds(for: $0).contains(pagePoint)
                || $0.sourceHitBounds.contains { $0.contains(pagePoint) }
        }
    }

    private func displayedBounds(for marker: NoteMarker) -> CGRect {
        guard pressedMarker?.id == marker.id,
              let previewCenter
        else { return marker.bounds }
        return CGRect(
            x: previewCenter.x - marker.bounds.width / 2,
            y: previewCenter.y - marker.bounds.height / 2,
            width: marker.bounds.width,
            height: marker.bounds.height
        )
    }

    private func displayedMaskBounds(for marker: NoteMarker) -> CGRect {
        marker.maskBounds
            .union(marker.bounds)
            .union(displayedBounds(for: marker))
    }

    private func pagePoint(for viewPoint: NSPoint) -> CGPoint {
        pagePointForOverlayPoint?(CGPoint(x: viewPoint.x, y: viewPoint.y))
            ?? CGPoint(
                x: viewPoint.x + pageBounds.minX,
                y: viewPoint.y + pageBounds.minY
            )
    }

    func setExternalDragPreview(_ marker: NoteMarker?, center: CGPoint?) {
        pressedMarker = marker
        if let marker, let center {
            previewCenter = clampedCenter(center, for: marker)
            didDragMarker = true
        } else {
            previewCenter = nil
            didDragMarker = false
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func clampedCenter(_ center: CGPoint, for marker: NoteMarker) -> CGPoint {
        let movingBounds = marker.sourceHitBounds.reduce(marker.bounds) { $0.union($1) }
        guard movingBounds.width <= pageBounds.width,
              movingBounds.height <= pageBounds.height
        else { return CGPoint(x: marker.bounds.midX, y: marker.bounds.midY) }

        let minimumDelta = CGPoint(
            x: pageBounds.minX - movingBounds.minX,
            y: pageBounds.minY - movingBounds.minY
        )
        let maximumDelta = CGPoint(
            x: pageBounds.maxX - movingBounds.maxX,
            y: pageBounds.maxY - movingBounds.maxY
        )
        guard minimumDelta.x <= maximumDelta.x,
              minimumDelta.y <= maximumDelta.y
        else { return CGPoint(x: marker.bounds.midX, y: marker.bounds.midY) }

        let requestedDelta = CGPoint(
            x: center.x - marker.bounds.midX,
            y: center.y - marker.bounds.midY
        )
        return CGPoint(
            x: marker.bounds.midX + min(max(requestedDelta.x, minimumDelta.x), maximumDelta.x),
            y: marker.bounds.midY + min(max(requestedDelta.y, minimumDelta.y), maximumDelta.y)
        )
    }

    /// Markers take input so PDFKit cannot open its native note popup over the
    /// sticker and a drag can move it. Everywhere else the overlay is
    /// transparent to hit testing, so text selection, links and scrolling work.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let localPoint = convert(point, from: superview)
        return marker(at: localPoint) == nil ? nil : self
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for marker in markers {
            let frame = displayedBounds(for: marker)
            let rect = frame.offsetBy(dx: -pageBounds.minX, dy: -pageBounds.minY)
            addCursorRect(rect, cursor: .pointingHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let marker = marker(at: point) else { return }
        pressedMarker = marker
        dragStartPagePoint = pagePoint(for: point)
        let center = CGPoint(x: marker.bounds.midX, y: marker.bounds.midY)
        dragStartCenter = center
        previewCenter = center
        didDragMarker = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let marker = pressedMarker,
              let dragStartPagePoint,
              let dragStartCenter
        else { return }
        let pointer = pagePoint(for: convert(event.locationInWindow, from: nil))
        let delta = CGPoint(
            x: pointer.x - dragStartPagePoint.x,
            y: pointer.y - dragStartPagePoint.y
        )
        if !didDragMarker, hypot(delta.x, delta.y) > 3 {
            didDragMarker = true
        }
        guard didDragMarker else { return }
        previewCenter = clampedCenter(
            CGPoint(x: dragStartCenter.x + delta.x, y: dragStartCenter.y + delta.y),
            for: marker
        )
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let marker = pressedMarker else { return }
        let moved = didDragMarker
        let destination = previewCenter
        pressedMarker = nil
        dragStartPagePoint = nil
        dragStartCenter = nil
        previewCenter = nil
        didDragMarker = false
        if moved, let destination {
            onMarkerMoved?(marker, destination)
        } else if self.marker(at: point)?.id == marker.id {
            onMarkerActivated?(marker)
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let marker = self.marker(at: point) else { return nil }
        return onMarkerMenu?(marker)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawNoteMarkerMasks()
        drawSelectedMarkup()
        drawNoteStickerArtwork()
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
    private func drawNoteMarkerMasks() {
        guard let page else { return }
        let pageMarkers = markers.filter { $0.pageIndex == pageIndex }

        // Clear every native icon stack first. If two masks overlap, drawing
        // them in a separate pass prevents a later mask from erasing an earlier
        // sticker.
        for marker in pageMarkers {
            let rect = displayedBounds(for: marker).offsetBy(
                dx: -pageBounds.minX,
                dy: -pageBounds.minY
            )
            guard rect.width > 1, rect.height > 1 else { continue }
            let candidate = displayedMaskBounds(for: marker)
            let maskBounds = candidate.origin.x.isFinite
                && candidate.origin.y.isFinite
                && candidate.width.isFinite
                && candidate.height.isFinite
                && candidate.width > 0
                && candidate.height > 0
                ? candidate
                : marker.bounds
            let maskRect = maskBounds.offsetBy(
                dx: -pageBounds.minX,
                dy: -pageBounds.minY
            )
            drawPageBackground(in: maskRect, page: page)
        }
    }

    /// Draw the sticker artwork after selection so the masks cannot erase the
    /// selected-text outline and the sticker remains the topmost page overlay.
    private func drawNoteStickerArtwork() {
        let pageMarkers = markers.filter { $0.pageIndex == pageIndex }
        for marker in pageMarkers {
            let rect = displayedBounds(for: marker).offsetBy(
                dx: -pageBounds.minX,
                dy: -pageBounds.minY
            )
            guard rect.width > 1, rect.height > 1 else { continue }
            drawSticker(
                marker.style,
                at: rect,
                count: marker.count,
                showsCountBadge: marker.showsCountBadge
            )
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
        for annotation in pageCopy.annotations.reversed() {
            if NoteService.usesStickerPresentation(annotation)
                || annotation.type == "Popup"
                || annotation.type == "/Popup"
            {
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
        // PDF pages are transparent by default. Repainting only their content
        // would leave transparent pixels in this overlay, allowing PDFKit's
        // native note icon beneath the sticker to show through. PDFView presents
        // those transparent areas on a white page, so make that backdrop opaque
        // before redrawing the page content without the sticker annotations.
        context.setFillColor(NSColor.white.cgColor)
        context.fill(rect)
        context.translateBy(
            x: bounds.midX - renderedSize.width / 2 - crop.minX * scale,
            y: bounds.midY - renderedSize.height / 2 - crop.minY * scale
        )
        context.scaleBy(x: scale, y: scale)
        pageCopy.draw(with: .cropBox, to: context)
        context.restoreGState()
    }

    private func drawSticker(
        _ style: NoteStickerStyle,
        at frame: CGRect,
        count: Int,
        showsCountBadge: Bool
    ) {
        let artRect = CGRect(
            x: frame.minX,
            y: frame.midY - NoteService.markerDisplaySize / 2,
            width: NoteService.markerDisplaySize,
            height: NoteService.markerDisplaySize
        )

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

        guard showsCountBadge else { return }
        drawCountBadge(count, in: frame)
    }

    private func drawCountBadge(_ count: Int, in frame: CGRect) {
        let label = "\(max(count, 1))" as NSString
        let ink = NSColor(srgbRed: 0.37, green: 0.26, blue: 0.21, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: ink
        ]
        let textSize = label.size(withAttributes: attributes)
        let badgeWidth = max(14, textSize.width + 7)
        let badge = CGRect(
            x: frame.maxX - badgeWidth,
            y: frame.minY + 1,
            width: badgeWidth,
            height: 14
        )
        let outline = NSBezierPath(roundedRect: badge, xRadius: 7, yRadius: 7)
        NSColor.white.setFill()
        outline.fill()
        ink.withAlphaComponent(0.20).setStroke()
        outline.lineWidth = 0.7
        outline.stroke()
        label.draw(
            at: CGPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2),
            withAttributes: attributes
        )
    }

}
