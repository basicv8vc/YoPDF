import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import YoPDFCore

struct PDFReaderView: View {

    @ObservedObject var model: PDFDocumentModel

    @State private var isImporterPresented = false
    @State private var isDropTargeted = false
    @State private var prompt: Prompt?
    /// Installed on the window so closing it cannot drop unsaved edits.
    @State private var closeGuard = WindowCloseGuard()
    /// The open note composer, if any.
    @State private var noteComposer: NoteComposerPresentation?
    /// True while the next page click places a page note.
    @State private var isPlacingNote = false
    /// Converts page rectangles into popover anchors through the live PDFView.
    @State private var anchorResolver = PageAnchorResolver()

    /// Something the reader was asked to do that would discard edits.
    private enum PendingAction: Equatable {
        case open(URL)
        case closeWindow
        case quit
    }

    private enum Prompt: Identifiable {
        case unsavedChanges(PendingAction)
        case saveProblem(title: String, message: String, offersSaveAs: Bool)

        var id: String {
            switch self {
            case let .unsavedChanges(action):
                return "unsaved-\(String(describing: action))"
            case let .saveProblem(title, _, _):
                return "problem-\(title)"
            }
        }

        var title: String {
            switch self {
            case .unsavedChanges:
                return "Save changes before continuing?"
            case let .saveProblem(title, _, _):
                return title
            }
        }

        var message: String {
            switch self {
            case let .unsavedChanges(action):
                switch action {
                case let .open(url):
                    return "“\(url.lastPathComponent)” cannot be opened while this document has unsaved changes."
                case .closeWindow, .quit:
                    return "This document has changes that are not in the file yet."
                }
            case let .saveProblem(_, message, _):
                return message
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .frame(minWidth: 900, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            requestOpen(url)
        }
        .onOpenURL { url in
            requestOpen(url)
        }
        .focusedSceneValue(\.documentModel, model)
        .focusedSceneValue(\.openDocument, { isImporterPresented = true })
        .focusedSceneValue(\.saveDocument, { _ = performSave() })
        .focusedSceneValue(\.saveDocumentAs, { presentSaveAsPanel() })
        .focusedSceneValue(\.highlightSelection, { _ = model.addMarkup(.highlight) })
        .focusedSceneValue(\.underlineSelection, { _ = model.addMarkup(.underline) })
        .focusedSceneValue(\.addNote, { beginNote() })
        .background(
            WindowCloseGuardInstaller(
                guardObject: closeGuard,
                isDirty: { model.hasUnsavedChanges },
                editRevision: { model.editRevision },
                discardUnsavedChanges: { model.abandonUnsavedChanges() },
                onUnsavedChanges: handleCloseIntent
            )
        )
        .alert(
            prompt?.title ?? "",
            isPresented: Binding(
                get: { prompt != nil },
                set: { if !$0 { prompt = nil } }
            ),
            presenting: prompt
        ) { prompt in
            switch prompt {
            case let .unsavedChanges(action):
                Button("Save") { saveThen(action) }
                Button("Don’t Save", role: .destructive) { discardThen(action) }
                Button("Cancel", role: .cancel) {
                    self.prompt = nil
                    if action == .quit {
                        QuitSession.coordinator.cancel()
                    }
                }
            case let .saveProblem(_, _, offersSaveAs):
                if offersSaveAs {
                    Button("Save As…") {
                        self.prompt = nil
                        presentSaveAsPanel()
                    }
                }
                Button("OK", role: .cancel) { self.prompt = nil }
            }
        } message: { prompt in
            Text(prompt.message)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                isImporterPresented = true
            } label: {
                Label("Open", systemImage: "folder")
            }
            .help("Open a PDF (⌘O)")

            Divider().frame(height: 18)

            Button {
                model.goToPreviousPage()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!model.isLoaded || model.currentPageIndex == 0)
            .help("Previous page")

            pageIndicator

            Button {
                model.goToNextPage()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!model.isLoaded || model.currentPageIndex >= model.pageCount - 1)
            .help("Next page")

            Divider().frame(height: 18)

            Button {
                model.zoomOut()
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(!model.isLoaded)
            .help("Zoom out (⌘−)")

            zoomIndicator

            Button {
                model.zoomIn()
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(!model.isLoaded)
            .help("Zoom in (⌘+)")

            Button {
                model.fitToWindow()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .disabled(!model.isLoaded)
            .help("Fit to window")

            Divider().frame(height: 18)

            Button {
                model.addMarkup(.highlight)
            } label: {
                Label("Highlight", systemImage: "highlighter")
            }
            .disabled(!model.canAddMarkup(.highlight))
            .help("Highlight the selected text (⇧⌘H)")

            MarkupColorButton(
                title: "Highlight Colour",
                help: "Colour for new highlights",
                color: model.defaultMarkupColor(for: .highlight)
            ) { color in
                model.setDefaultMarkupColor(color, for: .highlight)
            }

            Button {
                model.addMarkup(.underline)
            } label: {
                Label("Underline", systemImage: "underline")
            }
            .disabled(!model.canAddMarkup(.underline))
            .help("Underline the selected text (⇧⌘U)")

            MarkupColorButton(
                title: "Underline Colour",
                help: "Colour for new underlines",
                color: model.defaultMarkupColor(for: .underline)
            ) { color in
                model.setDefaultMarkupColor(color, for: .underline)
            }

            Divider().frame(height: 18)

            Button {
                if isPlacingNote {
                    isPlacingNote = false
                } else {
                    beginNote()
                }
            } label: {
                Label(
                    isPlacingNote ? "Cancel Note" : "Add Note",
                    systemImage: isPlacingNote ? "xmark.circle" : "note.text.badge.plus"
                )
            }
            .disabled(!model.canCreateNote)
            .help(
                isPlacingNote
                    ? "Click a page to place the note, or press Esc to cancel"
                    : "Note the selected text, or click a page to place a note (⇧⌘N)"
            )

            if let selected = model.selectedMarkup {
                Divider().frame(height: 18)

                MarkupColorButton(
                    title: "\(selected.kind.title) Colour",
                    help: "Change the selected annotation’s colour",
                    color: selected.color
                ) { color in
                    model.recolorSelectedMarkup(to: color)
                }
                .disabled(!model.canModifySelectedMarkup)

                Button {
                    model.convertSelectedMarkup()
                } label: {
                    Image(systemName: selected.kind.converted.symbolName)
                }
                .disabled(!model.canModifySelectedMarkup)
                .help("Convert to \(selected.kind.converted.title)")

                if model.selectedMarkupIsProtected {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .help("This annotation is protected and cannot be changed")
                }

                Button {
                    model.deleteSelectedMarkup()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(!model.canModifySelectedMarkup)
                .help("Delete the selected annotation")
            }

            Button {
                performSave()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .disabled(!model.isLoaded)
            .help("Save changes (⌘S)")

            Spacer(minLength: 8)

            if model.hasUnsavedChanges {
                Label("Edited", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("This document has unsaved changes")
                    .accessibilityLabel("Unsaved changes")
            }

            if let fileURL = model.fileURL {
                Text(fileURL.lastPathComponent)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(fileURL.path)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var pageIndicator: some View {
        Text(model.pageCount == 0 ? "– / –" : "\(model.displayPageNumber) / \(model.pageCount)")
            .font(.callout.monospacedDigit())
            .foregroundStyle(model.isLoaded ? .primary : .secondary)
            .frame(minWidth: 68)
            .accessibilityLabel(
                model.pageCount == 0
                    ? "No pages"
                    : "Page \(model.displayPageNumber) of \(model.pageCount)"
            )
    }

    private var zoomIndicator: some View {
        Text(model.isAutoScaling ? "Fit" : "\(Int((model.zoomScale * 100).rounded()))%")
            .font(.callout.monospacedDigit())
            .foregroundStyle(model.isLoaded ? .primary : .secondary)
            .frame(minWidth: 48)
            .accessibilityLabel(
                model.isAutoScaling
                    ? "Zoom: fit to window"
                    : "Zoom: \(Int((model.zoomScale * 100).rounded())) percent"
            )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.isLoaded {
            PDFViewerRepresentable(
                document: model.document,
                currentPageIndex: Binding(
                    get: { model.currentPageIndex },
                    set: { model.goToPage($0) }
                ),
                selection: Binding(
                    get: { model.currentSelection },
                    set: { model.updateSelection($0) }
                ),
                autoScales: model.isAutoScaling,
                zoomScale: model.zoomScale,
                onScaleChange: { model.updateEffectiveScale($0) },
                selectedMarkup: model.selectedMarkup,
                noteMarkers: model.noteMarkers,
                isPlacingNote: isPlacingNote,
                annotationRevision: model.annotationRevision,
                changedAnnotationPageIndices: model.changedAnnotationPageIndices,
                onMarkupClick: { point, page in
                    model.selectMarkup(at: point, on: page)
                },
                onNoteHit: { point, page in
                    model.noteSelection(at: point, on: page)
                },
                onNoteActivated: { note, anchor in
                    presentNoteComposer(for: note, anchor: anchor)
                },
                onPlaceNote: { point, page, anchor in
                    placePageNote(at: point, on: page, anchor: anchor)
                },
                onCancelPlacement: { isPlacingNote = false },
                makeMenuItems: { context in
                    pageMenuItems(for: context)
                },
                anchorResolver: anchorResolver
            )
            .id(model.loadGeneration)
            .popover(
                item: $noteComposer,
                attachmentAnchor: .rect(.rect(noteComposer?.anchorRect ?? Self.fallbackAnchor)),
                arrowEdge: .top
            ) { presentation in
                NoteComposerView(presentation: presentation, model: model) {
                    noteComposer = nil
                }
            }
            // A composer describes one anchor in one document. Both a new
            // document and a changed annotation set can invalidate it — the note
            // may have been undone, deleted or reloaded from disk — so it closes
            // rather than saving into something it no longer describes.
            .onChange(of: model.loadGeneration) { _, _ in
                noteComposer = nil
                isPlacingNote = false
            }
            .onChange(of: model.annotationRevision) { _, _ in
                noteComposer = nil
            }
            .alert(
                "Couldn’t open this document",
                isPresented: Binding(
                    get: { model.lastError != nil },
                    set: { if !$0 { model.dismissError() } }
                )
            ) {
                Button("OK", role: .cancel) { model.dismissError() }
            } message: {
                Text(model.lastError?.errorDescription ?? "Unknown error.")
            }
        } else {
            emptyState
        }
    }

    /// Used only if the PDFView is not in the hierarchy yet, which cannot happen
    /// while a document is loaded. A visible popover beats no popover.
    private static let fallbackAnchor = CGRect(x: 180, y: 180, width: 1, height: 1)

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Open a PDF to get started")
                .font(.title3.weight(.medium))
            Text("Drag a PDF here, or choose one from disk.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open PDF…") {
                isImporterPresented = true
            }
            .keyboardShortcut("o", modifiers: .command)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .contentShape(Rectangle())
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
                .padding(24)
                .allowsHitTesting(false)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            requestOpen(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    // MARK: - Opening

    /// The single entry point for opening a document.
    ///
    /// Everything that can open a file goes through here so that a document with
    /// unsaved edits is never replaced without the user choosing what happens to
    /// them. The model enforces the same rule; this is where the choice is
    /// offered.
    private func requestOpen(_ url: URL) {
        guard !model.hasUnsavedChanges else {
            prompt = .unsavedChanges(.open(url))
            return
        }
        model.open(url: url)
    }

    // MARK: - Saving

    /// Saves and, on failure, turns the outcome into a prompt. Returns whether
    /// the edits are known to be on disk.
    @discardableResult
    private func performSave() -> Bool {
        present(model.save())
    }

    private func presentSaveAsPanel() {
        guard model.isLoaded else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = model.fileURL?.lastPathComponent ?? "\(model.title).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        present(model.saveAs(to: url, overwrite: true))
    }

    @discardableResult
    private func present(_ outcome: SaveOutcome) -> Bool {
        switch outcome {
        case .saved:
            return true
        case let .savedUnverified(reason, editsOnDisk):
            prompt = .saveProblem(
                title: editsOnDisk ? "Saved, but not verified" : "The save could not be confirmed",
                message: reason,
                offersSaveAs: !editsOnDisk
            )
            return editsOnDisk
        case let .conflict(error):
            prompt = .saveProblem(
                title: "The file changed on disk",
                message: (error.errorDescription ?? "The file was not written.")
                    + " Your changes are still here — save a copy to keep them.",
                offersSaveAs: true
            )
            return false
        case let .uncertain(reason, recovery):
            var message = reason
            if !recovery.isEmpty {
                message += "\n\nNothing was deleted. These copies were kept:\n"
                    + recovery.map(\.path).joined(separator: "\n")
            }
            prompt = .saveProblem(
                title: "The save stopped in an unclear state",
                message: message,
                offersSaveAs: false
            )
            return false
        case let .failed(error):
            prompt = .saveProblem(
                title: "Couldn’t save",
                message: error.errorDescription ?? "The file was not written.",
                offersSaveAs: offersSaveAs(for: error)
            )
            return false
        }
    }

    private func offersSaveAs(for error: SaveError) -> Bool {
        switch error {
        case .noDocument, .serializationFailed, .sessionUnavailable:
            return false
        case let .store(storeError):
            switch storeError {
            case .sessionClosed, .sessionNeedsRefresh, .reloadRequired:
                return false
            case .unsupportedFileSituation(.sameFileAsCurrent, _):
                // Save As would only fail again: the panel has to pick another
                // location, not repeat the same one.
                return false
            default:
                return true
            }
        }
    }

    // MARK: - Notes

    /// Starts the Add Note action: a selection becomes a note about that text,
    /// otherwise the reader switches to placing a page note.
    private func beginNote() {
        guard model.canCreateNote else { return }

        guard let draft = model.selectionNoteDraft() else {
            isPlacingNote = true
            return
        }

        isPlacingNote = false
        let anchor = anchorResolver.containerRect(
            forPageBounds: draft.bounds,
            pageIndex: draft.pageIndex
        )
        noteComposer = NoteComposerPresentation(
            mode: .create(draft),
            anchorRect: anchor ?? Self.fallbackAnchor,
            pageLabel: draft.pageLabel,
            excerpt: draft.excerpt,
            contents: "",
            paper: .honey
        )
    }

    /// Captures a page note at a click point.
    ///
    /// The draft comes from the model, which never looks at the text selection:
    /// a page note created while text is still selected must not inherit it.
    private func placePageNote(at point: CGPoint, on page: PDFPage, anchor: CGRect) {
        guard let draft = model.pageNoteDraft(at: point, on: page) else { return }
        isPlacingNote = false
        noteComposer = NoteComposerPresentation(
            mode: .create(draft),
            anchorRect: anchor,
            pageLabel: draft.pageLabel,
            excerpt: nil,
            contents: "",
            paper: .honey
        )
    }

    private func presentNoteComposer(for note: NoteSelection, anchor: CGRect) {
        isPlacingNote = false
        noteComposer = NoteComposerPresentation(
            mode: .edit(note),
            anchorRect: anchor,
            pageLabel: note.pageLabel,
            excerpt: note.excerpt,
            contents: note.contents,
            paper: note.paperColor
        )
    }

    // MARK: - Annotation menu

    /// Right-click actions for the click that opened the menu.
    ///
    /// Note items come first because a marker is a small target on top of the
    /// page; the markup items keep their existing order and behaviour.
    private func pageMenuItems(for context: PageMenuContext) -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        if let note = context.note {
            let anchor = context.anchorRect
            items.append(MarkupActionMenuItem(title: "Edit Note") { [note] in
                presentNoteComposer(for: note, anchor: anchor)
            })
            if model.notePermissions(for: note).canDelete {
                items.append(MarkupActionMenuItem(title: "Delete Note") { [note] in
                    _ = model.deleteNote(note)
                })
            }
        } else if model.canCreateNote {
            let point = context.pagePoint
            let page = context.page
            let anchor = context.anchorRect
            items.append(MarkupActionMenuItem(title: "Add Note Here") {
                placePageNote(at: point, on: page, anchor: anchor)
            })
        }

        let markup = markupMenuItems()
        if !items.isEmpty, !markup.isEmpty {
            items.append(.separator())
        }
        items.append(contentsOf: markup)
        return items
    }

    /// Right-click actions for the selected markup.
    ///
    /// Built from the same model methods as the toolbar so there is no second
    /// editing path. The standard PDFView menu is kept and extended, not
    /// replaced: zoom, display mode and navigation still belong to PDFKit.
    private func markupMenuItems() -> [NSMenuItem] {
        guard let selected = model.selectedMarkup else { return [] }
        let canModify = model.canModifySelectedMarkup
        var items: [NSMenuItem] = []

        if model.selectedMarkupIsProtected {
            items.append(MarkupActionMenuItem(
                title: "Protected annotation",
                isEnabled: false
            ) {})
        }

        let colorItem = NSMenuItem(
            title: "\(selected.kind.title) Colour",
            action: nil,
            keyEquivalent: ""
        )
        let colorMenu = NSMenu(title: "\(selected.kind.title) Colour")
        let currentHex = MarkupColorPalette.hex(from: selected.color)
        for preset in MarkupColorPalette.presets {
            let item = MarkupActionMenuItem(title: preset.name) { [weak model] in
                _ = model?.recolorSelectedMarkup(to: preset.color)
            }
            item.state = currentHex?.caseInsensitiveCompare(preset.hex) == .orderedSame
                ? .on
                : .off
            item.isEnabled = canModify
            colorMenu.addItem(item)
        }
        colorItem.submenu = colorMenu
        colorItem.isEnabled = canModify
        items.append(colorItem)

        let convert = MarkupActionMenuItem(
            title: "Convert to \(selected.kind.converted.title)"
        ) { [weak model] in
            _ = model?.convertSelectedMarkup()
        }
        convert.isEnabled = canModify
        items.append(convert)

        let delete = MarkupActionMenuItem(title: "Delete \(selected.kind.title)") { [weak model] in
            _ = model?.deleteSelectedMarkup()
        }
        delete.isEnabled = canModify
        items.append(delete)

        return items
    }

    // MARK: - Unsaved changes

    private func handleCloseIntent(_ intent: WindowCloseGuard.Intent) {
        switch intent {
        case .windowClose:
            prompt = .unsavedChanges(.closeWindow)
        case .quit:
            prompt = .unsavedChanges(.quit)
        }
    }

    private func saveThen(_ action: PendingAction) {
        prompt = nil
        guard performSave() else {
            // A failed save stops the quit before termination is requested.
            // Any "Don't Save" answers collected from other windows belong to
            // an attempt that is no longer running, so they must not survive.
            if action == .quit { QuitSession.coordinator.cancel() }
            return
        }
        perform(action)
    }

    private func discardThen(_ action: PendingAction) {
        prompt = nil
        switch action {
        case let .open(url):
            // Opening with `discardingUnsavedChanges` only abandons the edits as
            // part of a successful switch. If the new file cannot be opened, the
            // old document, its annotations and its dirty state all stay — so a
            // failed open cannot leave a document on screen whose edits nothing
            // is protecting any more.
            model.open(url: url, discardingUnsavedChanges: true)
        case .closeWindow:
            // The window is closing now, so the edits really are being discarded.
            model.abandonUnsavedChanges()
            closeGuard.closeNow()
        case .quit:
            // The window stays open and keeps its dirty state: this records the
            // answer for the quit that is still in progress. The edits are only
            // abandoned once every dirty window has answered, in `commit`.
            QuitSession.coordinator.approveDiscard(of: closeGuard)
            perform(action)
        }
    }

    private func perform(_ action: PendingAction) {
        switch action {
        case let .open(url):
            model.open(url: url)
        case .closeWindow:
            closeGuard.closeNow()
        case .quit:
            NSApp.terminate(nil)
        }
    }
}
