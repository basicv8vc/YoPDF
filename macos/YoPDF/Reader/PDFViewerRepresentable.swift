import AppKit
import PDFKit
import SwiftUI
import YoPDFCore

/// Bridges PDFView into SwiftUI.
///
/// The wrapper owns no reader state: page index and zoom live in
/// `PDFDocumentModel`, and the coordinator only reports what PDFView did. The
/// one exception is the text selection, which is written back through a binding
/// because the model needs it to decide whether a highlight is possible — and
/// because clearing it from the model must clear it in the view.
struct PDFViewerRepresentable: NSViewRepresentable {

    let document: PDFDocument?
    @Binding var currentPageIndex: Int
    @Binding var selection: PDFSelection?
    let autoScales: Bool
    let zoomScale: CGFloat
    let onScaleChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.backgroundColor = .windowBackgroundColor
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self

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

        // The model cleared the selection: the highlight consumed it, or a new
        // document replaced it. PDFView keeps drawing its own selection until
        // told otherwise, so it has to be cleared here rather than in the model.
        if selection == nil, view.currentSelection != nil {
            view.clearSelection()
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
        private weak var pdfView: PDFView?

        init(parent: PDFViewerRepresentable) {
            self.parent = parent
        }

        func attach(to view: PDFView) {
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
