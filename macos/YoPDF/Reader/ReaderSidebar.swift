import AppKit
import PDFKit
import SwiftUI
import YoPDFCore

/// The three document-scoped views in the reader sidebar.
enum ReaderSidebarSection: String, CaseIterable, Identifiable {
    case outline
    case thumbnails
    case annotations

    var id: Self { self }

    var title: String {
        switch self {
        case .outline: "Outline"
        case .thumbnails: "Thumbnails"
        case .annotations: "Annotations"
        }
    }

    var symbolName: String {
        switch self {
        case .outline: "list.bullet.indent"
        case .thumbnails: "square.grid.2x2"
        case .annotations: "pencil.tip.crop.circle"
        }
    }
}

struct ReaderSidebarActions {
    let toggle: @MainActor () -> Void
    let select: @MainActor (ReaderSidebarSection) -> Void
}

/// A document-first navigation panel. It indexes the open PDF only; it never
/// takes ownership of the file or creates a separate library.
struct ReaderSidebar: View {

    @ObservedObject var model: PDFDocumentModel
    @ObservedObject var pdfViewHandle: PDFViewHandle
    @Binding var selection: ReaderSidebarSection
    let onSelectDestination: (PDFDestination) -> Void

    @State private var annotationItems: [SidebarAnnotationItem] = []

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider()

            sectionContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear(perform: refreshAnnotationItems)
        .onChange(of: model.loadGeneration) { _, _ in
            refreshAnnotationItems()
        }
        .onChange(of: model.annotationRevision) { _, _ in
            refreshAnnotationItems()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(selection.title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let countLabel {
                    Text(countLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 4) {
                ForEach(ReaderSidebarSection.allCases) { section in
                    let isSelected = selection == section

                    Button {
                        withAnimation(.easeInOut(duration: 0.14)) {
                            selection = section
                        }
                    } label: {
                        Image(systemName: section.symbolName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.accentColor.opacity(0.12))
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(section.title)
                    .accessibilityLabel(section.title)
                    .accessibilityValue(isSelected ? "Selected" : "")
                }
            }
            .buttonStyle(.borderless)
        }
    }

    private var countLabel: String? {
        switch selection {
        case .outline:
            nil
        case .thumbnails:
            "\(model.pageCount) pages"
        case .annotations:
            "\(annotationItems.count)"
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selection {
        case .outline:
            outlineContent
        case .thumbnails:
            PDFThumbnailSidebarRepresentable(pdfViewHandle: pdfViewHandle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Page thumbnails")
        case .annotations:
            annotationsContent
        }
    }

    @ViewBuilder
    private var outlineContent: some View {
        let roots = outlineRoots
        if roots.isEmpty {
            SidebarEmptyState(
                symbolName: "list.bullet.indent",
                title: "No outline",
                message: "This PDF does not include a document outline."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(roots.enumerated()), id: \.offset) { entry in
                        OutlineSidebarRow(
                            outline: entry.element,
                            path: "\(entry.offset)",
                            depth: 0,
                            currentPageIndex: model.currentPageIndex,
                            onSelectDestination: onSelectDestination
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private var annotationsContent: some View {
        if annotationItems.isEmpty {
            SidebarEmptyState(
                symbolName: "pencil.tip.crop.circle",
                title: "No annotations",
                message: "Highlights, underlines, and notes in this PDF will appear here."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(annotationItems) { item in
                        AnnotationSidebarRow(
                            item: item,
                            isCurrentPage: item.pageIndex == model.currentPageIndex
                        ) {
                            navigate(to: item)
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    private var outlineRoots: [PDFOutline] {
        guard let root = model.document?.outlineRoot else { return [] }
        return (0..<root.numberOfChildren).compactMap { root.child(at: $0) }
    }

    private func refreshAnnotationItems() {
        guard let document = model.document else {
            annotationItems = []
            return
        }

        var result: [SidebarAnnotationItem] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }

            let visibleAnnotations = page.annotations.enumerated().filter { entry in
                let type = entry.element.type?.lowercased()
                return type != "popup" && type != "widget" && type != "link"
            }
            let sortedAnnotations = visibleAnnotations.sorted { left, right in
                let leftY = left.element.bounds.maxY
                let rightY = right.element.bounds.maxY
                let safeLeftY = leftY.isFinite ? leftY : 0
                let safeRightY = rightY.isFinite ? rightY : 0
                if safeLeftY != safeRightY { return safeLeftY > safeRightY }
                return left.offset < right.offset
            }

            for (index, entry) in sortedAnnotations.enumerated() {
                result.append(
                    SidebarAnnotationItem(
                        id: "\(pageIndex)-\(index)",
                        pageIndex: pageIndex,
                        annotation: entry.element
                    )
                )
            }
        }
        annotationItems = result
    }

    private func navigate(to item: SidebarAnnotationItem) {
        guard let document = model.document,
              let page = document.page(at: item.pageIndex)
        else { return }

        let pageBounds = page.bounds(for: .cropBox)
        guard pageBounds.minX.isFinite, pageBounds.minY.isFinite,
              pageBounds.maxX.isFinite, pageBounds.maxY.isFinite
        else {
            model.goToPage(item.pageIndex)
            return
        }

        let bounds = item.annotation.bounds
        let point: CGPoint
        if bounds.minX.isFinite, bounds.minY.isFinite,
           bounds.maxX.isFinite, bounds.maxY.isFinite {
            point = CGPoint(
                x: min(max(bounds.midX, pageBounds.minX), pageBounds.maxX),
                y: min(max(bounds.maxY, pageBounds.minY), pageBounds.maxY)
            )
        } else {
            point = CGPoint(
                x: pageBounds.midX,
                y: pageBounds.midY
            )
        }
        onSelectDestination(PDFDestination(page: page, at: point))
    }
}

private struct OutlineSidebarRow: View {
    let outline: PDFOutline
    let path: String
    let depth: Int
    let currentPageIndex: Int
    let onSelectDestination: (PDFDestination) -> Void

    @State private var isExpanded: Bool

    private static let maximumDepth = 48

    init(
        outline: PDFOutline,
        path: String,
        depth: Int,
        currentPageIndex: Int,
        onSelectDestination: @escaping (PDFDestination) -> Void
    ) {
        self.outline = outline
        self.path = path
        self.depth = depth
        self.currentPageIndex = currentPageIndex
        self.onSelectDestination = onSelectDestination
        self._isExpanded = State(initialValue: outline.isOpen)
    }

    private var children: Int { outline.numberOfChildren }
    private var canExpand: Bool { children > 0 && depth < Self.maximumDepth }

    private var destination: PDFDestination? {
        guard let destination = outline.destination,
              let page = destination.page,
              let document = outline.document,
              document.index(for: page) != NSNotFound
        else { return nil }
        return destination
    }

    private var isOnCurrentPage: Bool {
        guard let destination,
              let page = destination.page,
              let document = outline.document
        else { return false }
        return document.index(for: page) == currentPageIndex
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 2) {
                if canExpand {
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .foregroundStyle(.tertiary)
                            .frame(width: 20, height: 25)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Collapse section" : "Expand section")
                } else {
                    Color.clear.frame(width: 20, height: 25)
                }

                Button {
                    if let destination { onSelectDestination(destination) }
                } label: {
                    Text(title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(isOnCurrentPage ? Color.accentColor : Color.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, minHeight: 25, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(destination == nil)
                .help(destination == nil ? "This outline item has no page destination" : title)
            }
            .padding(.leading, CGFloat(min(depth, 8) * 12))

            if isExpanded, canExpand {
                ForEach(0..<children, id: \.self) { index in
                    if let child = outline.child(at: index) {
                        OutlineSidebarRow(
                            outline: child,
                            path: "\(path).\(index)",
                            depth: depth + 1,
                            currentPageIndex: currentPageIndex,
                            onSelectDestination: onSelectDestination
                        )
                    }
                }
            }
        }
        .id(path)
    }

    private var title: String {
        let label = outline.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return label.isEmpty ? "Untitled Section" : label
    }
}

private struct SidebarAnnotationItem: Identifiable {
    let id: String
    let pageIndex: Int
    let annotation: PDFAnnotation

    var typeLabel: String {
        switch annotation.type?.lowercased() {
        case "text": "Note"
        case "freetext": "Text"
        case "strikeout": "Strikethrough"
        case "fileattachment": "Attachment"
        case let type?:
            type.prefix(1).uppercased() + String(type.dropFirst())
        default: "Annotation"
        }
    }

    var title: String {
        if annotation.type?.lowercased() == "text",
           let contents = annotation.contents,
           let preview = Self.preview(contents) {
            return preview
        }
        return typeLabel
    }

    var iconName: String {
        switch annotation.type?.lowercased() {
        case "highlight": "highlighter"
        case "underline": "underline"
        case "strikeout": "strikethrough"
        case "text": "note.text"
        case "freetext": "text.alignleft"
        case "square": "square"
        case "circle": "circle"
        case "stamp": "stamp"
        case "ink": "pencil.tip"
        default: "pencil.tip.crop.circle"
        }
    }

    private static func preview(_ contents: String) -> String? {
        let words = contents.prefix(400).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        let normalized = words.joined(separator: " ")
        return String(normalized.prefix(96)) + (normalized.count > 96 ? "…" : "")
    }
}

private struct AnnotationSidebarRow: View {
    let item: SidebarAnnotationItem
    let isCurrentPage: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(nsColor: item.annotation.color))
                    .frame(width: 3)
                    .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("Page \(item.pageIndex + 1) · \(item.typeLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Image(systemName: item.iconName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isCurrentPage ? Color.accentColor.opacity(0.11) : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Go to page \(item.pageIndex + 1)")
    }
}

private struct SidebarEmptyState: View {
    let symbolName: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbolName)
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 190)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(18)
    }
}

private struct PDFThumbnailSidebarRepresentable: NSViewRepresentable {
    @ObservedObject var pdfViewHandle: PDFViewHandle

    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView(frame: .zero)
        view.thumbnailSize = CGSize(width: 136, height: 176)
        view.maximumNumberOfColumns = 1
        view.allowsDragging = false
        view.labelFont = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        view.backgroundColor = .controlBackgroundColor
        view.pdfView = pdfViewHandle.pdfView
        return view
    }

    func updateNSView(_ view: PDFThumbnailView, context: Context) {
        if view.pdfView !== pdfViewHandle.pdfView {
            view.pdfView = pdfViewHandle.pdfView
        }
    }
}
