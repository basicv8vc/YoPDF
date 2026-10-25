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
    @ObservedObject var navigationState: ReaderNavigationState
    @Binding var selection: ReaderSidebarSection
    let onSelectDestination: (PDFDestination) -> Void

    @State private var outlineKeyboardFocus = OutlineKeyboardFocusController()

    private var annotationItems: [SidebarAnnotationItem] {
        get { navigationState.annotationItems }
        nonmutating set { navigationState.annotationItems = newValue }
    }

    private var outlineItems: [OutlineSidebarItem] {
        get { navigationState.outlineItems }
        nonmutating set { navigationState.outlineItems = newValue }
    }

    private var selectedOutlineItemID: String? {
        get { navigationState.memory.selectedOutlineItemID }
        nonmutating set {
            navigationState.updateMemory { $0.selectOutlineItem(newValue) }
        }
    }

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
        .onAppear {
            prepareNavigationState()
        }
        .onChange(of: model.loadGeneration) { _, _ in
            navigationState.prepare(for: model.loadGeneration)
            outlineKeyboardFocus.clearFocus()
            prepareNavigationState()
        }
        .onChange(of: selection) { _, newSelection in
            if newSelection != .outline {
                outlineKeyboardFocus.clearFocus()
            }
            if newSelection == .annotations {
                indexAnnotationsIfNeeded()
            }
        }
        .onChange(of: model.annotationRevision) { _, _ in
            guard navigationState.memory.documentGeneration == model.loadGeneration,
                  navigationState.memory.hasAnnotationIndex
            else { return }
            refreshAnnotationItems()
        }
    }

    private func prepareNavigationState() {
        navigationState.prepare(for: model.loadGeneration)
        if navigationState.memory.needsOutlineLoad {
            refreshOutlineItems()
        }
        if selection == .annotations {
            indexAnnotationsIfNeeded()
        }
    }

    private func indexAnnotationsIfNeeded() {
        guard navigationState.memory.documentGeneration == model.loadGeneration,
              navigationState.memory.needsAnnotationIndex(for: model.annotationRevision)
        else { return }
        refreshAnnotationItems()
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
            GeometryReader { geometry in
                let thumbnailWidth = min(180, max(0, geometry.size.width - 40))

                PDFPageThumbnailList(
                    document: model.document,
                    currentPageIndex: model.currentPageIndex,
                    thumbnailSize: CGSize(
                        width: thumbnailWidth,
                        height: thumbnailWidth * 792 / 612
                    ),
                    onSelectPage: model.goToPage
                )
                .accessibilityLabel("Page thumbnails")
            }
        case .annotations:
            annotationsContent
        }
    }

    @ViewBuilder
    private var outlineContent: some View {
        if outlineItems.isEmpty {
            SidebarEmptyState(
                symbolName: "list.bullet.indent",
                title: "No outline",
                message: "This PDF does not include a document outline."
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(outlineItems) { item in
                            OutlineSidebarRow(
                                item: item,
                                currentPageIndex: model.currentPageIndex,
                                isSelected: selectedOutlineItemID == item.id,
                                onToggle: toggleOutlineItem,
                                onSelect: { selectOutlineItem(item.id, scrollProxy: proxy) }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .overlay(alignment: .topLeading) {
                    OutlineKeyboardCaptureRepresentable(focusController: outlineKeyboardFocus) { keyCode in
                        handleOutlineArrowKey(keyCode, scrollProxy: proxy)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
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

    private func refreshOutlineItems() {
        guard let root = model.document?.outlineRoot else {
            outlineItems = []
            navigationState.updateMemory { $0.markOutlineLoaded() }
            return
        }

        let requests = (0..<root.numberOfChildren).reversed().compactMap { index in
            root.child(at: index).map {
                OutlineNodeRequest(outline: $0, id: "\(index)", depth: 0)
            }
        }
        outlineItems = makeVisibleOutlineItems(from: requests, excluding: [ObjectIdentifier(root)])
        navigationState.updateMemory { $0.markOutlineLoaded() }
    }

    private func toggleOutlineItem(id: String) {
        guard let index = outlineItems.firstIndex(where: { $0.id == id }) else { return }
        let item = outlineItems[index]
        guard item.canExpand else { return }
        selectedOutlineItemID = id
        navigationState.updateMemory { $0.setOutlineItem(id, expanded: !item.isExpanded) }
        requestOutlineKeyboardFocus()

        if item.isExpanded {
            var endIndex = index + 1
            while endIndex < outlineItems.count, outlineItems[endIndex].depth > item.depth {
                endIndex += 1
            }
            outlineItems[index].isExpanded = false
            outlineItems.removeSubrange((index + 1)..<endIndex)
            return
        }

        let visibleOutlineIDs = Set(outlineItems.map { ObjectIdentifier($0.outline) })
        let requests = (0..<item.childCount).reversed().compactMap { childIndex in
            item.outline.child(at: childIndex).map {
                OutlineNodeRequest(
                    outline: $0,
                    id: "\(item.id).\(childIndex)",
                    depth: item.depth + 1
                )
            }
        }
        let descendants = makeVisibleOutlineItems(from: requests, excluding: visibleOutlineIDs)
        outlineItems[index].isExpanded = true
        outlineItems.insert(contentsOf: descendants, at: index + 1)
    }

    private func handleOutlineArrowKey(
        _ keyCode: UInt16,
        scrollProxy: ScrollViewProxy
    ) {
        switch keyCode {
        case 126: // Up
            moveOutlineSelection(by: -1, scrollProxy: scrollProxy)
        case 125: // Down
            moveOutlineSelection(by: 1, scrollProxy: scrollProxy)
        case 123: // Left
            moveOutlineSelectionToParent(scrollProxy: scrollProxy)
        case 124: // Right
            moveOutlineSelectionToChild(scrollProxy: scrollProxy)
        default:
            break
        }
    }

    private func moveOutlineSelection(by offset: Int, scrollProxy: ScrollViewProxy) {
        guard !outlineItems.isEmpty else { return }

        let currentIndex = selectedOutlineItemID.flatMap { id in
            outlineItems.firstIndex { $0.id == id }
        }
        let nextIndex = currentIndex.map { $0 + offset } ?? (offset > 0 ? 0 : outlineItems.count - 1)
        guard outlineItems.indices.contains(nextIndex) else { return }
        selectOutlineItem(outlineItems[nextIndex].id, scrollProxy: scrollProxy)
    }

    private func moveOutlineSelectionToParent(scrollProxy: ScrollViewProxy) {
        guard let selectedOutlineItemID,
              let index = outlineItems.firstIndex(where: { $0.id == selectedOutlineItemID })
        else { return }

        let item = outlineItems[index]
        if item.canExpand, item.isExpanded {
            toggleOutlineItem(id: item.id)
            return
        }
        guard item.depth > 0,
              let parent = outlineItems[..<index].reversed().first(where: {
                  $0.depth == item.depth - 1
              })
        else { return }
        selectOutlineItem(parent.id, scrollProxy: scrollProxy)
    }

    private func moveOutlineSelectionToChild(scrollProxy: ScrollViewProxy) {
        guard let selectedOutlineItemID,
              let index = outlineItems.firstIndex(where: { $0.id == selectedOutlineItemID })
        else { return }

        let item = outlineItems[index]
        guard item.canExpand else { return }
        if !item.isExpanded {
            toggleOutlineItem(id: item.id)
            return
        }
        guard index + 1 < outlineItems.count,
              outlineItems[index + 1].depth > item.depth
        else { return }
        selectOutlineItem(outlineItems[index + 1].id, scrollProxy: scrollProxy)
    }

    private func selectOutlineItem(_ id: String, scrollProxy: ScrollViewProxy) {
        guard let item = outlineItems.first(where: { $0.id == id }) else { return }
        selectedOutlineItemID = id
        if let destination = item.destination {
            onSelectDestination(destination)
        }
        requestOutlineKeyboardFocus()
        scrollProxy.scrollTo(id, anchor: .center)
    }

    private func requestOutlineKeyboardFocus() {
        DispatchQueue.main.async {
            outlineKeyboardFocus.focus()
        }
    }

    /// Build a flat list of rows that are currently visible. Keeping outline
    /// hierarchy out of the SwiftUI view tree lets LazyVStack virtualize every
    /// row, including descendants of expanded sections.
    private func makeVisibleOutlineItems(
        from requests: [OutlineNodeRequest],
        excluding existingOutlineIDs: Set<ObjectIdentifier>
    ) -> [OutlineSidebarItem] {
        guard let document = model.document else { return [] }

        var result: [OutlineSidebarItem] = []
        var seenOutlineIDs = existingOutlineIDs
        var pending = requests

        while let request = pending.popLast() {
            let outlineID = ObjectIdentifier(request.outline)
            guard seenOutlineIDs.insert(outlineID).inserted else { continue }

            let children = request.outline.numberOfChildren
            let canExpand = children > 0 && request.depth < OutlineSidebarItem.maximumDepth
            let candidateDestination = request.outline.destination
            let destinationPageIndex = candidateDestination?.page.flatMap { page in
                let index = document.index(for: page)
                return index == NSNotFound ? nil : index
            }
            let destination = destinationPageIndex == nil ? nil : candidateDestination
            let label = request.outline.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let defaultExpanded = request.outline.isOpen && canExpand
            let item = OutlineSidebarItem(
                id: request.id,
                outline: request.outline,
                title: label.isEmpty ? "Untitled Section" : label,
                depth: request.depth,
                childCount: children,
                destination: destination,
                destinationPageIndex: destinationPageIndex,
                isExpanded: navigationState.memory.isExpanded(
                    for: request.id,
                    defaultValue: defaultExpanded
                ) && canExpand
            )
            result.append(item)

            if item.isExpanded {
                for childIndex in stride(from: children - 1, through: 0, by: -1) {
                    guard let child = request.outline.child(at: childIndex) else { continue }
                    pending.append(
                        OutlineNodeRequest(
                            outline: child,
                            id: "\(request.id).\(childIndex)",
                            depth: request.depth + 1
                        )
                    )
                }
            }
        }
        return result
    }

    private func refreshAnnotationItems() {
        guard let document = model.document else {
            annotationItems = []
            return
        }

        annotationItems = PDFAnnotationSidebarIndex.entries(in: document).map {
            SidebarAnnotationItem(id: $0.id, pageIndex: $0.pageIndex, annotation: $0.annotation)
        }
        navigationState.updateMemory {
            $0.markAnnotationIndexUpdated(revision: model.annotationRevision)
        }
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

private struct OutlineNodeRequest {
    let outline: PDFOutline
    let id: String
    let depth: Int
}

struct OutlineSidebarItem: Identifiable {
    static let maximumDepth = 48

    let id: String
    let outline: PDFOutline
    let title: String
    let depth: Int
    let childCount: Int
    let destination: PDFDestination?
    let destinationPageIndex: Int?
    var isExpanded: Bool

    var canExpand: Bool {
        childCount > 0 && depth < Self.maximumDepth
    }
}

private struct OutlineSidebarRow: View {
    let item: OutlineSidebarItem
    let currentPageIndex: Int
    let isSelected: Bool
    let onToggle: (String) -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            if item.canExpand {
                Button {
                    onToggle(item.id)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(item.isExpanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                        .frame(width: 20, height: 25)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.isExpanded ? "Collapse section" : "Expand section")
            } else {
                Color.clear.frame(width: 20, height: 25)
            }

            Button {
                onSelect()
            } label: {
                Text(item.title)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(item.destinationPageIndex == currentPageIndex
                        ? Color.accentColor : Color.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 25, alignment: .leading)
                    .contentShape(Rectangle())
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.accentColor.opacity(0.12))
                        }
                    }
            }
            .buttonStyle(.plain)
            .help(item.destination == nil ? "This outline item has no page destination" : item.title)
        }
        .padding(.leading, CGFloat(min(item.depth, 8) * 12))
    }
}

@MainActor
private final class OutlineKeyboardFocusController {
    private weak var captureView: OutlineKeyboardCaptureView?
    private var focusRequested = false
    private var keyMonitor: Any?

    func attach(_ view: OutlineKeyboardCaptureView) {
        captureView = view
        if focusRequested {
            removeKeyMonitor()
            installKeyMonitor()
        }
    }

    func focus() {
        focusRequested = true
        installKeyMonitor()
    }

    func clearFocus() {
        focusRequested = false
        removeKeyMonitor()
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    func detach(_ view: OutlineKeyboardCaptureView) {
        guard captureView === view else { return }
        clearFocus()
        captureView = nil
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil,
              let view = captureView,
              let window = view.window
        else { return }

        let windowNumber = window.windowNumber
        let outlineFrameInWindow = view.convert(view.bounds, to: nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            let eventWindowNumber = event.window?.windowNumber
            guard eventWindowNumber == windowNumber else { return event }

            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                let clickLocation = event.locationInWindow
                if !outlineFrameInWindow.contains(clickLocation) {
                    MainActor.assumeIsolated {
                        self?.clearFocus()
                    }
                }
                return event
            }

            let modifiers = event.modifierFlags
            let keyCode = event.keyCode
            guard !modifiers.contains(.command),
                  !modifiers.contains(.control),
                  !modifiers.contains(.option),
                  !modifiers.contains(.shift),
                  [123, 124, 125, 126].contains(keyCode)
            else { return event }

            MainActor.assumeIsolated {
                self?.handleArrowKey(keyCode, windowNumber: windowNumber)
            }
            return nil
        }
    }

    private func handleArrowKey(_ keyCode: UInt16, windowNumber: Int) {
        guard focusRequested,
              captureView?.window?.windowNumber == windowNumber
        else { return }
        captureView?.onArrowKey?(keyCode)
    }
}

/// Supplies the Outline viewport bounds and arrow-key callback to the scoped
/// local event monitor.
@MainActor
private final class OutlineKeyboardCaptureView: NSView {
    var onArrowKey: ((UInt16) -> Void)?
}

@MainActor
private struct OutlineKeyboardCaptureRepresentable: NSViewRepresentable {
    let focusController: OutlineKeyboardFocusController
    let onArrowKey: (UInt16) -> Void

    func makeCoordinator() -> OutlineKeyboardFocusController {
        focusController
    }

    func makeNSView(context: Context) -> OutlineKeyboardCaptureView {
        let view = OutlineKeyboardCaptureView(frame: .zero)
        view.onArrowKey = onArrowKey
        focusController.attach(view)
        return view
    }

    func updateNSView(_ view: OutlineKeyboardCaptureView, context: Context) {
        view.onArrowKey = onArrowKey
        focusController.attach(view)
    }

    static func dismantleNSView(
        _ view: OutlineKeyboardCaptureView,
        coordinator: OutlineKeyboardFocusController
    ) {
        coordinator.detach(view)
    }
}

struct SidebarAnnotationItem: Identifiable {
    let id: String
    let pageIndex: Int
    let annotation: PDFAnnotation

    var typeLabel: String {
        switch PDFAnnotationTypeName.normalized(annotation.type) {
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
        if PDFAnnotationTypeName.normalized(annotation.type) == "text",
           let contents = annotation.contents,
           let preview = Self.preview(contents) {
            return preview
        }
        return typeLabel
    }

    var iconName: String {
        switch PDFAnnotationTypeName.normalized(annotation.type) {
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

private struct PDFPageThumbnailList: View {
    let document: PDFDocument?
    let currentPageIndex: Int
    let thumbnailSize: CGSize
    let onSelectPage: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if let document {
                        ForEach(0..<document.pageCount, id: \.self) { pageIndex in
                            if let page = document.page(at: pageIndex) {
                                Button {
                                    onSelectPage(pageIndex)
                                } label: {
                                    VStack(spacing: 5) {
                                        PDFPageThumbnail(page: page, maximumSize: thumbnailSize)

                                        Text("\(pageIndex + 1)")
                                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                                            .foregroundStyle(isCurrentPage(pageIndex) ? Color.accentColor : Color.primary)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5)
                                    .background {
                                        if isCurrentPage(pageIndex) {
                                            RoundedRectangle(cornerRadius: 7)
                                                .fill(Color.accentColor.opacity(0.09))
                                        }
                                    }
                                    .contentShape(RoundedRectangle(cornerRadius: 7))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Page \(pageIndex + 1)")
                                .accessibilityValue(isCurrentPage(pageIndex) ? "Current page" : "")
                                .id(pageIndex)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .onAppear {
                scrollToCurrentPage(using: proxy, animated: false)
            }
            .onChange(of: currentPageIndex) { _, _ in
                scrollToCurrentPage(using: proxy, animated: true)
            }
        }
    }

    private func isCurrentPage(_ pageIndex: Int) -> Bool {
        pageIndex == currentPageIndex
    }

    private func scrollToCurrentPage(using proxy: ScrollViewProxy, animated: Bool) {
        guard let document,
              currentPageIndex >= 0,
              currentPageIndex < document.pageCount
        else { return }

        let scroll = {
            proxy.scrollTo(currentPageIndex, anchor: .center)
        }
        if animated {
            withAnimation(.easeInOut(duration: 0.18), scroll)
        } else {
            scroll()
        }
    }
}

private struct PDFPageThumbnail: View {
    let page: PDFPage
    let maximumSize: CGSize

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: image.size.width, height: image.size.height)
                    .background(Color.white)
                    .overlay(Rectangle().stroke(Color.black.opacity(0.16), lineWidth: 0.6))
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
            } else {
                Rectangle()
                    .fill(Color.white)
                    .frame(width: placeholderSize.width, height: placeholderSize.height)
                    .overlay(Rectangle().stroke(Color.black.opacity(0.12), lineWidth: 0.6))
            }
        }
        .task(id: maximumSize) {
            image = page.thumbnail(of: maximumSize, for: .cropBox)
        }
    }

    private var placeholderSize: CGSize {
        var pageBounds = page.bounds(for: .cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        if rotation == 90 || rotation == 270 {
            pageBounds.size = CGSize(width: pageBounds.height, height: pageBounds.width)
        }

        guard pageBounds.width > 0, pageBounds.height > 0,
              maximumSize.width > 0, maximumSize.height > 0
        else { return maximumSize }

        let scale = min(maximumSize.width / pageBounds.width, maximumSize.height / pageBounds.height)
        return CGSize(width: pageBounds.width * scale, height: pageBounds.height * scale)
    }
}
