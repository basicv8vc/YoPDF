import AppKit
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
        .frame(minWidth: 720, minHeight: 520)
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
        .focusedSceneValue(\.highlightSelection, { _ = model.addHighlightToSelection() })
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
                model.addHighlightToSelection()
            } label: {
                Label("Highlight", systemImage: "highlighter")
            }
            .disabled(!model.canAddHighlight)
            .help("Highlight the selected text (⇧⌘H)")

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
                onScaleChange: { model.updateEffectiveScale($0) }
            )
            .id(model.loadGeneration)
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
