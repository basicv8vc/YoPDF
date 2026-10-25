import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import YoPDFCore

struct PDFReaderView: View {

    @ObservedObject var model: PDFDocumentModel
    @ObservedObject var updateController: SparkleUpdateController
    @ObservedObject var recentDocuments: RecentDocumentsStore
    @ObservedObject var fileOpenRequests: FileOpenRequestQueue

    @State private var isImporterPresented = false
    @State private var pendingRecentRelink: RecentDocument?
    /// A Finder request stays reserved while its Save / Discard / Cancel prompt
    /// is visible, so another event cannot replace the action in that prompt.
    @State private var finderOpenRequestAwaitingResolution = false
    @State private var finderOpenRequestID: UUID?
    @State private var isDropTargeted = false
    @State private var prompt: Prompt?
    @State private var isSidebarVisible = true
    @State private var sidebarSection: ReaderSidebarSection = .thumbnails
    @StateObject private var readerNavigationState = ReaderNavigationState()
    @State private var pendingNavigationDestination: PDFDestination?
    @State private var navigationRevision = 0
    @State private var isSearchPresented = false
    @State private var searchQuery = ""
    @FocusState private var isSearchFieldFocused: Bool
    /// Installed on the window so closing it cannot drop unsaved edits.
    @State private var closeGuard = WindowCloseGuard()
    /// The window's one note composer, and the draft that outlives its popover.
    ///
    /// The text is not `@State` here or in the popover: both are rebuilt often
    /// enough — a save, another annotation edit, a click outside — that either
    /// would throw typed text away.
    @StateObject private var composerStore = NoteComposerStore()
    @StateObject private var searchSession = PDFSearchSession()
    /// True while the next page click places a page note.
    @State private var isPlacingNote = false
    /// Converts page rectangles into popover anchors through the live PDFView.
    @State private var anchorResolver = PageAnchorResolver()

    #if DEBUG
    /// Test-only launch hook for deterministic screenshot and GUI runs. It is
    /// compiled out of Release builds and does nothing unless the environment
    /// variable is present.
    @State private var didOpenScreenshotPDF = false
    #endif

    /// Something the reader was asked to do that could discard work.
    private enum PendingAction: Equatable {
        case open(URL)
        case relink(URL, RecentDocument)
        case save
        case saveAs
        case closeWindow
        case quit
        /// Replacing the open composer with another note.
        case compose(ComposerTarget)

        enum ComposerTarget: Equatable {
            case draft(NoteDraft, CGRect)
            case note(NoteSelection, CGRect)
            case group(NoteSelection, CGRect)
        }

        var readerAction: ReaderAction {
            switch self {
            case let .open(url): return .open(url)
            case let .relink(url, _): return .open(url)
            case .save: return .save
            case .saveAs: return .saveAs
            case .closeWindow: return .closeWindow
            case .quit: return .quit
            case .compose: return .compose
            }
        }
    }

    private enum Prompt: Identifiable, Equatable {
        /// The note has text that is not in the document yet.
        case draftChanges(PendingAction)
        case unsavedChanges(PendingAction)
        case saveProblem(title: String, message: String, offersSaveAs: Bool)
        case recentDocumentUnavailable(RecentDocument)

        var id: String {
            switch self {
            case let .draftChanges(action):
                return "draft-\(String(describing: action))"
            case let .unsavedChanges(action):
                return "unsaved-\(String(describing: action))"
            case let .saveProblem(title, _, _):
                return "problem-\(title)"
            case let .recentDocumentUnavailable(item):
                return "recent-\(item.id)"
            }
        }

        var title: String {
            switch self {
            case .draftChanges:
                return "Save this note first?"
            case .unsavedChanges:
                return "Save changes before continuing?"
            case let .saveProblem(title, _, _):
                return title
            case .recentDocumentUnavailable:
                return "Couldn’t open recent document"
            }
        }

        var message: String {
            switch self {
            case let .draftChanges(action):
                return Self.draftMessage(for: action)
            case let .unsavedChanges(action):
                switch action {
                case let .open(url):
                    return "“\(url.lastPathComponent)” cannot be opened while this document has unsaved changes."
                case let .relink(url, _):
                    return "“\(url.lastPathComponent)” cannot be opened while this document has unsaved changes."
                case .closeWindow, .quit:
                    return "This document has changes that are not in the file yet."
                case .save, .saveAs, .compose:
                    return "This document has changes that are not in the file yet."
                }
            case let .saveProblem(_, message, _):
                return message
            case let .recentDocumentUnavailable(item):
                return "YoPDF can no longer resolve the saved location for “\(item.displayName)”. Locate the PDF to reconnect this recent item."
            }
        }

        /// Saving the note is not saving the file, and the wording has to say so
        /// — otherwise "Save Note" reads as "my text is on disk now".
        private static func draftMessage(for action: PendingAction) -> String {
            let base = "The note you are writing is not in the document yet."
            switch action {
            case .save:
                return base + " Saving it adds the note to the document, and the file is written straight after."
            case .saveAs:
                return base + " Save the note, or discard it, before saving a copy of the file."
            case let .open(url):
                return base + " “\(url.lastPathComponent)” cannot be opened until you save or discard it."
            case let .relink(url, _):
                return base + " “\(url.lastPathComponent)” cannot be opened until you save or discard it."
            case .closeWindow, .quit:
                return base + " Saving it puts the note in the document; the file itself still has to be saved."
            case .compose:
                return base + " Save it or discard it before opening another note."
            }
        }
    }

    var body: some View {
        alertReader
    }

    private var alertReader: some View {
        titlebarReader.alert(
            prompt?.title ?? "",
            isPresented: promptPresentation,
            presenting: prompt
        ) { prompt in
            switch prompt {
            case let .draftChanges(action):
                Button("Save Note") { saveDraftThen(action) }
                Button("Discard Draft", role: .destructive) { discardDraftThen(action) }
                Button("Cancel", role: .cancel) { cancel(action) }
            case let .unsavedChanges(action):
                Button("Save") { saveThen(action) }
                Button("Don’t Save", role: .destructive) { discardThen(action) }
                Button("Cancel", role: .cancel) { cancel(action) }
            case let .saveProblem(_, _, offersSaveAs):
                if offersSaveAs {
                    Button("Save As…") {
                        self.prompt = nil
                        presentSaveAsPanel()
                        finishFinderOpenRequestIfResolved()
                    }
                }
                Button("OK", role: .cancel) {
                    self.prompt = nil
                    finishFinderOpenRequestIfResolved()
                }
            case let .recentDocumentUnavailable(item):
                Button("Relink…") { beginRecentRelink(item) }
                Button("Cancel", role: .cancel) {
                    self.prompt = nil
                    finishFinderOpenRequestIfResolved()
                }
            }
        } message: { prompt in
            Text(prompt.message)
        }
    }

    private var titlebarReader: some View {
        closeGuardReader.background(
            TitlebarUpdateIndicatorInstaller(updateController: updateController)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
    }

    private var closeGuardReader: some View {
        let readerID = closeGuard.readerID
        return focusedReader.background(
            WindowCloseGuardInstaller(
                guardObject: closeGuard,
                unsavedWork: { unsavedWork },
                discardDraft: {
                    // Termination is committed, so the draft goes with the
                    // document's edits. Until this point a "Discard Draft" is
                    // only an intent for the quit attempt.
                    composerStore.end()
                },
                discardDocumentChanges: {
                    model.abandonUnsavedChanges()
                },
                onUnsavedChanges: handleCloseIntent,
                onWindowAvailable: {
                    // SwiftUI can attach the representable after the window's
                    // first key event. Retry after the view update so a file
                    // queued during launch is not stranded in that case.
                    fileOpenRequests.readerWindowDidBecomeAvailable()
                    Task { @MainActor in
                        await Task.yield()
                        openFileRequestIfReady()
                    }
                },
                onWindowClosed: {
                    guard fileOpenRequests.readerWindowDidClose(readerID: readerID) else { return }
                    if WindowCloseGuard.installedGuards(among: NSApp.windows).isEmpty {
                        fileOpenRequests.openReaderWindowIfAvailable()
                    }
                }
            )
        )
    }

    private var focusedReader: some View {
        lifecycleReader
            .focusedSceneValue(\.documentModel, model)
            .focusedSceneValue(\.openDocument, { isImporterPresented = true })
            .focusedSceneValue(\.openRecentDocument, { requestOpenRecent($0) })
            .focusedSceneValue(\.saveDocument, { requestSave() })
            .focusedSceneValue(\.saveDocumentAs, { requestSaveAs() })
            .focusedSceneValue(\.exportAnnotations, { exportAnnotationsAsMarkdown() })
            .focusedSceneValue(\.findInDocument, { showSearch() })
            .focusedSceneValue(\.findNextSearchResult, findNextSearchResultAction)
            .focusedSceneValue(\.findPreviousSearchResult, findPreviousSearchResultAction)
            .focusedSceneValue(\.highlightSelection, { _ = model.addMarkup(.highlight) })
            .focusedSceneValue(\.underlineSelection, { _ = model.addMarkup(.underline) })
            .focusedSceneValue(\.addNote, { beginNote() })
            .focusedSceneValue(
                \.readerSidebarActions,
                ReaderSidebarActions(
                    toggle: { toggleSidebar() },
                    select: { showSidebarSection($0) }
                )
            )
    }

    private var lifecycleReader: some View {
        urlReader
            .onChange(of: fileOpenRequests.revision) { _, _ in
                openFileRequestIfReady()
            }
            .onChange(of: prompt) { _, newPrompt in
                guard newPrompt == nil else { return }
                finishFinderOpenRequestIfResolved()
                // If a Finder event arrived while another alert was visible,
                // let SwiftUI dismiss it before presenting the open request.
                Task { @MainActor in
                    await Task.yield()
                    openFileRequestIfReady()
                }
            }
            .onChange(of: isImporterPresented) { _, isPresented in
                guard !isPresented else { return }
                Task { @MainActor in
                    await Task.yield()
                    openFileRequestIfReady()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                guard let window = notification.object as? NSWindow,
                      window === closeGuard.window
                else { return }
                openFileRequestIfReady()
            }
            .onChange(of: model.autoSaveFailureRevision) { _, _ in
                presentLatestAutoSaveFailure()
            }
            .onChange(of: model.loadGeneration) { _, _ in
                closeSearch()
                pendingNavigationDestination = nil
            }
            .onChange(of: model.isLoaded) { _, isLoaded in
                if !isLoaded { closeSearch() }
            }
            .onChange(of: model.document.map(ObjectIdentifier.init)) { _, _ in
                searchSession.documentWasReplaced(with: model.document)
            }
            .onChange(of: searchQuery) { _, query in
                guard isSearchPresented else { return }
                searchSession.search(query, in: model.document)
            }
            .onDisappear(perform: closeSearch)
    }

    private var urlReader: some View {
        importedReader
            .task {
                openScreenshotPDFIfConfigured()
                openFileRequestIfReady()
            }
    }

    /// Prefer the key reader, then the main/frontmost reader. Finder can create
    /// a visible window without making it key; requiring key status strands
    /// the URL indefinitely. All readers use the same choice so only one takes
    /// the request, including while the app is inactive.
    private func openFileRequestIfReady() {
        let readers = WindowCloseGuard.installedGuards(among: NSApp.windows).compactMap(\.window)
        let readerIDs = Set(readers.map(ObjectIdentifier.init))
        let orderedReaders = (NSApp.orderedWindows + readers).filter {
            readerIDs.contains(ObjectIdentifier($0))
        }
        let target = FileOpenRequestQueue.preferredReader(
            key: NSApp.keyWindow.map(ObjectIdentifier.init),
            main: NSApp.mainWindow.map(ObjectIdentifier.init),
            orderedReaders: orderedReaders.map(ObjectIdentifier.init)
        )
        guard prompt == nil,
              !isImporterPresented,
              let window = closeGuard.window,
              target == ObjectIdentifier(window),
              let request = fileOpenRequests.takeNext(readerID: closeGuard.readerID)
        else { return }

        // Finder may deliver a file while the application is inactive or a
        // recreated reader has not become key. Taking the URL first prevents
        // the ensuing key notification from delivering the same request twice.
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        finderOpenRequestID = request.id
        finderOpenRequestAwaitingResolution = promptKind(for: .open(request.url)) != .none
        requestOpen(request.url)
        if !finderOpenRequestAwaitingResolution {
            finishFinderOpenRequest(requestID: request.id)
        }
    }

    private func finishFinderOpenRequestIfResolved() {
        guard finderOpenRequestAwaitingResolution,
              prompt == nil,
              let requestID = finderOpenRequestID
        else { return }
        finderOpenRequestAwaitingResolution = false
        finishFinderOpenRequest(requestID: requestID)
    }

    private func finishFinderOpenRequest(requestID: UUID) {
        guard finderOpenRequestID == requestID else { return }
        finderOpenRequestID = nil
        fileOpenRequests.finishRequest(requestID: requestID, readerID: closeGuard.readerID)
    }

    private var importedReader: some View {
        readerLayout
            .frame(minWidth: 900, minHeight: 520)
            .background(Color(nsColor: .windowBackgroundColor))
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false
            ) { result in
                handleImportResult(result)
            }
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        if let item = pendingRecentRelink {
            pendingRecentRelink = nil
            guard case let .success(urls) = result, let url = urls.first else { return }
            requestOpen(url, relinking: item)
            return
        }
        guard case let .success(urls) = result, let url = urls.first else { return }
        requestOpen(url)
    }

    private func presentLatestAutoSaveFailure() {
        // Do not replace an action prompt already on screen. The toolbar keeps
        // the failure visible; dismissing the current prompt leaves the user
        // free to retry or save a copy.
        guard prompt == nil, let outcome = model.lastAutoSaveOutcome else { return }
        _ = present(outcome)
    }

    private var promptPresentation: Binding<Bool> {
        Binding(
            get: { prompt != nil },
            set: {
                if !$0 {
                    prompt = nil
                }
            }
        )
    }

    private func openScreenshotPDFIfConfigured() {
        #if DEBUG
        let environmentPath = ProcessInfo.processInfo.environment["YOPDF_SCREENSHOT_PDF"]
        let preferencePath = UserDefaults.standard.string(forKey: "YOPDF_SCREENSHOT_PDF")
        guard !didOpenScreenshotPDF,
              let path = environmentPath ?? preferencePath
        else { return }
        didOpenScreenshotPDF = true
        requestOpen(URL(fileURLWithPath: path))
        #endif
    }

    private var readerLayout: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if isSearchPresented {
                searchBar
                Divider()
            }
            content
        }
    }

    // MARK: - Toolbar

    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isSidebarVisible.toggle()
        }
    }

    private func showSidebarSection(_ section: ReaderSidebarSection) {
        withAnimation(.easeInOut(duration: 0.18)) {
            sidebarSection = section
            isSidebarVisible = true
        }
    }

    private func navigate(to destination: PDFDestination) {
        guard let document = model.document,
              let page = destination.page
        else { return }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return }

        model.goToPage(pageIndex)
        pendingNavigationDestination = destination
        navigationRevision &+= 1
    }

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
                toggleSidebar()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .disabled(!model.isLoaded)
            .help(isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
            .accessibilityLabel(isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")

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
                requestSave()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .disabled(!model.isLoaded)
            .help("Save changes (⌘S)")

            Spacer(minLength: 8)

            // A popover is dismissed by any click outside it. The draft survives
            // that, so there has to be a way back to it.
            if composerStore.hasUncommittedChanges && !composerStore.isPresented {
                Button {
                    composerStore.isPresented = true
                } label: {
                    Label("Note Draft", systemImage: "square.and.pencil")
                        .font(.caption)
                }
                .help("A note you have not saved yet is still here. Click to reopen it.")
                .accessibilityLabel("Reopen the unsaved note draft")
            }

            switch model.autoSaveStatus {
            case .idle:
                if model.hasUnsavedChanges {
                    Label("Edited", systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("This document has unsaved changes")
                        .accessibilityLabel("Unsaved changes")
                }
            case .pending, .saving:
                Label("Saving…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("YoPDF will save annotation changes automatically.")
            case .saved:
                Label("Saved", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("All annotation changes are saved")
            case .failed:
                Label("Auto-save failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .help("The edits are still in memory. See the save details and retry or save a copy.")
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

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Find in PDF", text: $searchQuery)
                .textFieldStyle(.plain)
                .focused($isSearchFieldFocused)
                .accessibilityIdentifier("pdf-search-field")
                .onSubmit(showNextSearchResult)
                .onExitCommand(perform: closeSearch)
                .frame(minWidth: 220, maxWidth: 360)

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                    isSearchFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear search")
                .help("Clear search")
            }

            Text(searchResultSummary)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 84, alignment: .leading)
                .accessibilityIdentifier("pdf-search-result-summary")
                .accessibilityLabel(searchResultAccessibilityLabel)

            Button(action: showPreviousSearchResult) {
                Image(systemName: "chevron.up")
            }
            .disabled(searchSession.results.isEmpty)
            .accessibilityLabel("Previous search result")
            .help("Previous result (⇧⌘G)")

            Button(action: showNextSearchResult) {
                Image(systemName: "chevron.down")
            }
            .disabled(searchSession.results.isEmpty)
            .accessibilityLabel("Next search result")
            .help("Next result (⌘G)")

            Button(action: closeSearch) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Close search")
            .help("Close search (Esc)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var findNextSearchResultAction: (@MainActor () -> Void)? {
        guard !searchSession.results.isEmpty || searchSession.isSearching else { return nil }
        return { showNextSearchResult() }
    }

    private var findPreviousSearchResultAction: (@MainActor () -> Void)? {
        guard !searchSession.results.isEmpty || searchSession.isSearching else { return nil }
        return { showPreviousSearchResult() }
    }

    private var searchResultSummary: String {
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        if searchSession.isSearching {
            return "Searching…"
        }
        guard let currentResultIndex = searchSession.currentResultIndex,
              !searchSession.results.isEmpty
        else {
            return "No matches"
        }
        return "\(currentResultIndex + 1) of \(searchSession.results.count)"
    }

    private var searchResultAccessibilityLabel: String {
        if searchSession.isSearching {
            return "Searching"
        }
        guard let currentResultIndex = searchSession.currentResultIndex,
              !searchSession.results.isEmpty
        else {
            return searchResultSummary.isEmpty ? "No search results" : searchResultSummary
        }
        return "Result \(currentResultIndex + 1) of \(searchSession.results.count)"
    }

    private func showSearch() {
        guard model.isLoaded else { return }
        if isSearchPresented {
            focusSearchField(selectingQuery: true)
            return
        }
        isSearchPresented = true
        searchSession.search(searchQuery, in: model.document)
        focusSearchField(selectingQuery: false)
    }

    private func closeSearch() {
        if let pdfView = anchorResolver.pdfView {
            if isSearchPresented {
                pdfView.window?.makeFirstResponder(pdfView)
            }
        }
        searchSession.clear()
        searchQuery = ""
        isSearchPresented = false
        isSearchFieldFocused = false
    }

    private func focusSearchField(selectingQuery: Bool) {
        isSearchFieldFocused = true
        guard selectingQuery else { return }
        Task { @MainActor in
            await Task.yield()
            (anchorResolver.pdfView?.window?.firstResponder as? NSTextView)?.selectAll(nil)
        }
    }

    private func showNextSearchResult() {
        moveSearchResult(by: 1)
    }

    private func showPreviousSearchResult() {
        moveSearchResult(by: -1)
    }

    private func moveSearchResult(by offset: Int) {
        guard !searchSession.results.isEmpty || searchSession.isSearching,
              let pdfView = anchorResolver.pdfView,
              pdfView.document === model.document
        else { return }

        searchSession.move(by: offset)
        guard let nextSelection = searchSession.currentSelection else { return }
        pdfView.activeSearchSelection = nextSelection
        pdfView.go(to: nextSelection)
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
            let searchBelongsToDisplayedDocument = searchSession.document === model.document
            HStack(spacing: 0) {
                if isSidebarVisible {
                    ReaderSidebar(
                        model: model,
                        navigationState: readerNavigationState,
                        selection: $sidebarSection,
                        onSelectDestination: { navigate(to: $0) }
                    )
                    .frame(width: 250)

                    Divider()
                }

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
                    zoomCommandRevision: model.zoomCommandRevision,
                    navigationDestination: pendingNavigationDestination,
                    navigationRevision: navigationRevision,
                    onScaleChange: { model.updateEffectiveScale($0) },
                    onManualMagnification: { model.setAutoScaling(false) },
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
                        requestNoteComposer(note, anchor: anchor)
                    },
                    onNoteMoved: { note, center in
                        _ = model.moveNoteMarker(note, to: center)
                    },
                    onPlaceNote: { point, page, anchor in
                        placePageNote(at: point, on: page, anchor: anchor)
                    },
                    onCancelPlacement: { isPlacingNote = false },
                    searchSelections: searchBelongsToDisplayedDocument ? searchSession.results : [],
                    activeSearchSelection: searchBelongsToDisplayedDocument
                        ? searchSession.currentSelection
                        : nil,
                    searchResultsRevision: searchSession.resultsRevision,
                    makeMenuItems: { context in
                        pageMenuItems(for: context)
                    },
                    anchorResolver: anchorResolver
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(model.loadGeneration)
                .popover(
                    isPresented: $composerStore.isPresented,
                    attachmentAnchor: .rect(.rect(composerStore.session?.anchorRect ?? Self.fallbackAnchor)),
                    arrowEdge: .top
                ) {
                    if let session = composerStore.session {
                        NoteComposerView(session: session, model: model) {
                            composerStore.end()
                        } onEditGroupEntry: { group, entry in
                            guard let note = model.noteSelection(forThreadEntry: entry, in: group) else {
                                return
                            }
                            let anchor = anchorResolver.containerRect(
                                forPageBounds: group.bounds,
                                pageIndex: group.pageIndex
                            ) ?? Self.fallbackAnchor
                            requestCompose(.note(note, anchor))
                        }
                        .id(session.id)
                    }
                }
            }
            // A composer describes one anchor in one document, so a new document
            // or a changed annotation set can invalidate it. It is never closed
            // on those changes alone: closing a composer that holds text is how
            // the text gets lost. A composer with nothing to lose is closed when
            // its target is gone; one with text stays open and explains itself.
            .onChange(of: model.loadGeneration) { _, _ in
                isPlacingNote = false
                pendingNavigationDestination = nil
                composerStore.reconcile(with: model)
            }
            .onChange(of: model.annotationRevision) { _, _ in
                composerStore.reconcile(with: model)
            }
            .onChange(of: composerStore.isPresented) { _, presented in
                if !presented { composerStore.discardIfClean() }
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

            if !recentDocuments.items.isEmpty {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Recent Documents")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(Array(recentDocuments.items.prefix(5))) { item in
                            Button {
                                requestOpenRecent(item)
                            } label: {
                                Text(item.displayName)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(item.lastKnownPath)
                        }
                    }
                    .frame(maxWidth: 360, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
            }
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
    /// Everything that can open a file goes through here so that neither a
    /// document with unsaved edits nor a note that is still only in the composer
    /// is replaced without the user choosing what happens to it.
    private func requestOpen(_ url: URL, relinking item: RecentDocument? = nil) {
        let action: PendingAction = item.map { .relink(url, $0) } ?? .open(url)
        switch promptKind(for: action) {
        case .none:
            perform(action)
        case .draft:
            prompt = .draftChanges(action)
        case .document:
            prompt = .unsavedChanges(action)
        }
    }

    private func beginRecentRelink(_ item: RecentDocument) {
        pendingRecentRelink = item
        prompt = nil
        Task { @MainActor in
            await Task.yield()
            isImporterPresented = true
        }
    }

    private func requestOpenRecent(_ item: RecentDocument) {
        do {
            requestOpen(try recentDocuments.resolveURL(for: item))
        } catch {
            prompt = .recentDocumentUnavailable(item)
        }
    }

    // MARK: - Saving

    /// ⌘S. The note is resolved first: a document save writes the PDF as it is,
    /// so saving the file with a pending note would put the note's text nowhere.
    private func requestSave() {
        switch promptKind(for: .save) {
        case .draft:
            prompt = .draftChanges(.save)
        case .none, .document:
            performSave()
        }
    }

    private func requestSaveAs() {
        guard model.isLoaded else { return }
        switch promptKind(for: .saveAs) {
        case .draft:
            prompt = .draftChanges(.saveAs)
        case .none, .document:
            presentSaveAsPanel()
        }
    }

    private func promptKind(for action: PendingAction) -> ReaderPrompt {
        ReaderPromptPolicy.prompt(
            for: action.readerAction,
            draftHasChanges: composerStore.hasUncommittedChanges,
            documentHasChanges: model.hasUnsavedChanges
        )
    }

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
        let response = model.withAutoSavePaused { panel.runModal() }
        guard response == .OK, let url = panel.url else { return }
        present(model.saveAs(to: url, overwrite: true))
    }

    private func exportAnnotationsAsMarkdown() {
        guard model.isLoaded, let document = model.document else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.nameFieldStringValue = suggestedMarkdownFilename(for: model.title)

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let markdown = AnnotationMarkdownExporter.markdown(for: document, fallbackTitle: model.title)
        do {
            try Data(markdown.utf8).write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t Export Annotations"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func suggestedMarkdownFilename(for title: String) -> String {
        let safeTitle = title
            .replacingOccurrences(of: "/", with: "∕")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(safeTitle.isEmpty ? "Annotations" : safeTitle).md"
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
        requestCompose(.draft(draft, anchor ?? Self.fallbackAnchor))
    }

    /// Captures a page note at a click point.
    ///
    /// The draft comes from the model, which never looks at the text selection:
    /// a page note created while text is still selected must not inherit it.
    private func placePageNote(at point: CGPoint, on page: PDFPage, anchor: CGRect) {
        guard let draft = model.pageNoteDraft(at: point, on: page) else { return }
        isPlacingNote = false
        requestCompose(.draft(draft, anchor))
    }

    /// Opens a composer, unless doing so would replace a draft that has text.
    ///
    /// Clicking another marker while a composer is open dismisses the popover
    /// first, so this is a real path to losing typed text — the same one a save
    /// takes, and it gets the same question.
    private func requestCompose(_ target: PendingAction.ComposerTarget) {
        if promptKind(for: .compose(target)) == .draft {
            prompt = .draftChanges(.compose(target))
            return
        }
        startComposer(target)
    }

    /// A Shua thought opens its thread composer even when it is currently the
    /// only member. Mouse activation and the context menu share this route so
    /// one marker cannot expose two editing experiences.
    private func requestNoteComposer(_ note: NoteSelection, anchor: CGRect) {
        isPlacingNote = false
        let target: PendingAction.ComposerTarget = note.isShuaThought
            ? .group(note, anchor)
            : .note(note, anchor)
        requestCompose(target)
    }

    private func startComposer(_ target: PendingAction.ComposerTarget) {
        switch target {
        case let .draft(draft, anchor):
            composerStore.begin(
                mode: .create(draft),
                anchorRect: anchor,
                pageLabel: draft.pageLabel,
                excerpt: draft.excerpt,
                contents: "",
                style: .newNote
            )
        case let .note(note, anchor):
            composerStore.begin(
                mode: .edit(note),
                anchorRect: anchor,
                pageLabel: note.pageLabel,
                excerpt: note.excerpt,
                contents: note.contents,
                style: note.style
            )
        case let .group(note, anchor):
            composerStore.begin(
                mode: .group(note),
                anchorRect: anchor,
                pageLabel: note.pageLabel,
                excerpt: note.excerpt,
                contents: "",
                style: note.style
            )
        }
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
            let title = note.isShuaThought
                ? "Open Note Thread"
                : "Edit Note"
            items.append(MarkupActionMenuItem(title: title) { [note] in
                requestNoteComposer(note, anchor: anchor)
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

    /// Everything this window would lose if it closed without asking.
    ///
    /// Read live by the close guard, so a draft edit is visible to the quit
    /// coordinator without the model knowing that a composer exists.
    private var unsavedWork: UnsavedWork {
        UnsavedWork(
            documentRevision: model.editRevision,
            draftRevision: composerStore.revision,
            documentHasChanges: model.hasUnsavedChanges,
            draftHasChanges: composerStore.hasUncommittedChanges
        )
    }

    private func handleCloseIntent(_ intent: WindowCloseGuard.Intent) {
        switch intent {
        case .windowClose:
            switch promptKind(for: .closeWindow) {
            case .draft:
                prompt = .draftChanges(.closeWindow)
            case .document:
                prompt = .unsavedChanges(.closeWindow)
            case .none:
                // The guard only asks when something is unsaved, so this is only
                // reachable if the draft was resolved between the two reads.
                perform(.closeWindow)
            }
        case .quit:
            // The coordinator knows which half of the window is still
            // unanswered. A draft that was already approved for this attempt is
            // not asked about again.
            showQuitPrompt(for: QuitSession.coordinator.confirmationNeed(for: closeGuard))
        }
    }

    /// Continues the current quit attempt from whatever the coordinator says is
    /// still unanswered, or asks AppKit to terminate once nothing is left.
    private func continueQuit() {
        showQuitPrompt(for: QuitSession.coordinator.confirmationNeed(for: closeGuard))
    }

    private func showQuitPrompt(for need: QuitConfirmationNeed) {
        switch need {
        case .draft:
            prompt = .draftChanges(.quit)
        case .document:
            prompt = .unsavedChanges(.quit)
        case .none:
            perform(.quit)
        }
    }

    // MARK: - The draft prompt

    /// "Save Note": the note goes into the in-memory document, and only then
    /// does the interrupted action continue.
    ///
    /// A failed note save stops here. Continuing would let the next step save or
    /// reload the document, and the text that could not be written would be the
    /// only copy left.
    private func saveDraftThen(_ action: PendingAction) {
        prompt = nil
        switch composerStore.commit(using: model) {
        case let .failure(error):
            // A failed note save stops the quit before termination is
            // requested. Approvals collected from other windows belong to an
            // attempt that is no longer running, so they must not survive into
            // the next ⌘Q.
            if action == .quit { QuitSession.coordinator.cancel() }
            prompt = .saveProblem(
                title: "Couldn’t save the note",
                message: (error.errorDescription ?? "The note was not saved.")
                    + " Your text is still here.",
                offersSaveAs: false
            )
        case .success:
            if action == .quit {
                continueQuit()
            } else {
                proceed(afterDraft: action)
            }
        }
        finishFinderOpenRequestIfResolved()
    }

    /// "Discard Draft": the typed text is dropped by an explicit choice, and the
    /// interrupted action continues.
    ///
    /// Quit is the exception. The window stays open while the other windows are
    /// asked, so ending the draft here would lose text the user only agreed to
    /// discard for an attempt that may still be cancelled. The coordinator
    /// records the intent and ends the draft in `commit`, after termination is
    /// actually allowed.
    private func discardDraftThen(_ action: PendingAction) {
        prompt = nil
        switch QuitSession.coordinator.resolveDraftDiscard(
            for: action.readerAction,
            of: closeGuard
        ) {
        case .endedNow:
            composerStore.end()
            proceed(afterDraft: action)
        case let .deferredUntilQuitCommit(need):
            showQuitPrompt(for: need)
        }
        finishFinderOpenRequestIfResolved()
    }

    private func cancel(_ action: PendingAction) {
        prompt = nil
        if action == .quit { QuitSession.coordinator.cancel() }
        // The prompt never closed the composer, but the alert may have dismissed
        // the popover on its way in. Put it back: the draft is still there.
        if composerStore.hasSession { composerStore.isPresented = true }
        finishFinderOpenRequestIfResolved()
    }

    /// Continues an action once the draft is out of the way.
    ///
    /// Saving the note makes the document dirty, so the action that was
    /// interrupted still has to go through the ordinary unsaved-changes prompt —
    /// "Save Note" is not "the file is saved".
    private func proceed(afterDraft action: PendingAction) {
        switch ReaderPromptPolicy.promptAfterDraft(
            for: action.readerAction,
            documentHasChanges: model.hasUnsavedChanges
        ) {
        case .document:
            prompt = .unsavedChanges(action)
        case .draft:
            break
        case .none:
            perform(action)
        }
    }

    // MARK: - The document prompt

    private func saveThen(_ action: PendingAction) {
        prompt = nil
        // A deferred draft is still on screen because the user answered the
        // draft prompt with "Discard Draft". Saving the document changes the
        // document's revision, not the draft, so the same decision has to be
        // rebound to the new revisions before termination is retried.
        let keptDeferredDraft = action == .quit && composerStore.hasUncommittedChanges
        guard performSave() else {
            // A failed save stops the quit before termination is requested.
            // Any "Don't Save" answers collected from other windows belong to
            // an attempt that is no longer running, so they must not survive.
            if action == .quit { QuitSession.coordinator.cancel() }
            finishFinderOpenRequestIfResolved()
            return
        }
        if keptDeferredDraft {
            QuitSession.coordinator.approveDraftDiscard(of: closeGuard)
        }
        perform(action)
        finishFinderOpenRequestIfResolved()
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
        case let .relink(url, item):
            model.open(url: url, discardingUnsavedChanges: true, relinking: item)
        case .closeWindow:
            // The window is closing now, so the edits really are being discarded.
            model.abandonUnsavedChanges()
            closeGuard.closeNow()
        case .quit:
            // The window stays open and keeps its dirty state: this records the
            // document answer for the quit that is still in progress. The edits
            // are only abandoned once every dirty window has answered, in
            // `commit`. The draft approval, if any, is kept separately and
            // remains bound to its own revision.
            QuitSession.coordinator.approveDocumentDiscard(of: closeGuard)
            perform(action)
        case .save, .saveAs, .compose:
            // These never reach the document prompt: saving resolves it, and
            // composing is not a document-level action.
            break
        }
        finishFinderOpenRequestIfResolved()
    }

    private func perform(_ action: PendingAction) {
        switch action {
        case let .open(url):
            model.open(url: url)
        case let .relink(url, item):
            model.open(url: url, relinking: item)
        case .save:
            performSave()
        case .saveAs:
            presentSaveAsPanel()
        case .closeWindow:
            closeGuard.closeNow()
        case .quit:
            NSApp.terminate(nil)
        case let .compose(target):
            startComposer(target)
        }
    }
}
