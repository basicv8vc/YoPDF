import AppKit
import SwiftUI
import YoPDFCore

/// Menu-bar commands for the reader.
///
/// Every command reads the focused window's model, so with several windows open
/// `⌘+` or Page Down only affects the active one. Commands disable themselves
/// when no reader window is focused.
struct PDFReaderCommands: Commands {

    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var updateController: SparkleUpdateController
    @ObservedObject private var recentDocuments: RecentDocumentsStore

    @FocusedValue(\.documentModel) private var model
    @FocusedValue(\.openDocument) private var openDocument
    @FocusedValue(\.newWorkspaceTab) private var newWorkspaceTab
    @FocusedValue(\.closeWorkspaceTab) private var closeWorkspaceTab
    @FocusedValue(\.selectPreviousWorkspaceTab) private var selectPreviousWorkspaceTab
    @FocusedValue(\.selectNextWorkspaceTab) private var selectNextWorkspaceTab
    @FocusedValue(\.openRecentDocument) private var openRecentDocument
    @FocusedValue(\.saveDocument) private var saveDocument
    @FocusedValue(\.saveDocumentAs) private var saveDocumentAs
    @FocusedValue(\.exportAnnotations) private var exportAnnotations
    @FocusedValue(\.findInDocument) private var findInDocument
    @FocusedValue(\.findNextSearchResult) private var findNextSearchResult
    @FocusedValue(\.findPreviousSearchResult) private var findPreviousSearchResult
    @FocusedValue(\.highlightSelection) private var highlightSelection
    @FocusedValue(\.underlineSelection) private var underlineSelection
    @FocusedValue(\.addNote) private var addNote
    @FocusedValue(\.readerSidebarActions) private var sidebarActions

    init(updateController: SparkleUpdateController, recentDocuments: RecentDocumentsStore) {
        self.updateController = updateController
        self.recentDocuments = recentDocuments
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // Coding terminals and browsers use ⌘T for a new tab. This is the
            // workspace's own tab strip, not AppKit's window tabbing.
            Button("New Tab") {
                newWorkspaceTab?()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(newWorkspaceTab == nil)

            Button("Open PDF…") {
                openDocument?()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(openDocument == nil)

            Menu("Open Recent") {
                if recentDocuments.items.isEmpty {
                    Button("No Recent Documents") {}
                        .disabled(true)
                }

                ForEach(recentDocuments.items) { item in
                    Button(item.displayName) {
                        openRecentDocument?(item)
                    }
                    .help(item.lastKnownPath)
                    .disabled(openRecentDocument == nil)
                }

                if recentDocuments.canClear {
                    Divider()
                    Button("Clear Menu", role: .destructive) {
                        recentDocuments.clear()
                    }
                }
            }
            .disabled(!recentDocuments.canClear)

            Button("New Window") {
                openWindow(id: "reader")
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Close Tab") {
                closeWorkspaceTab?()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(closeWorkspaceTab == nil)

            Divider()

            // Kept with the other workspace tab commands so the File menu is
            // searched before any AppKit window-tabbing items with the same key
            // equivalents. Selection wraps at both ends (see WorkspaceState).
            Button("Show Previous Tab") {
                selectPreviousWorkspaceTab?()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(selectPreviousWorkspaceTab == nil)

            Button("Show Next Tab") {
                selectNextWorkspaceTab?()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(selectNextWorkspaceTab == nil)
        }

        // Annotation edits use the model's own history rather than PDFKit's
        // UndoManager. A cross-page mark is one entry, a recolour gesture is one
        // entry, and the history is cleared when Save As replaces the document.
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                model?.undoMarkup()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(model?.canUndoMarkup != true)

            Button("Redo") {
                model?.redoMarkup()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(model?.canRedoMarkup != true)
        }

        // Replaces the standard Save/Save As items: those would call into AppKit
        // document machinery this app does not use, and would skip the
        // unsaved-changes and save-outcome handling the reader owns.
        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                saveDocument?()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(model?.isLoaded != true)

            Button("Save As…") {
                saveDocumentAs?()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(model?.isLoaded != true)

            Divider()

            Button("Export Annotations as Markdown…") {
                exportAnnotations?()
            }
            .disabled(exportAnnotations == nil || model?.isLoaded != true)
        }

        CommandGroup(after: .pasteboard) {
            Button("Find in PDF") {
                findInDocument?()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(model?.isLoaded != true)

            Button("Find Next") {
                findNextSearchResult?()
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(findNextSearchResult == nil)

            Button("Find Previous") {
                findPreviousSearchResult?()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(findPreviousSearchResult == nil)
        }

        CommandMenu("Annotate") {
            Button("Highlight") {
                highlightSelection?()
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(model?.canAddMarkup(.highlight) != true)

            Button("Underline") {
                underlineSelection?()
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(model?.canAddMarkup(.underline) != true)

            // No key equivalent: ⇧⌘S is already Save As. Preview also leaves
            // Strike Out unshortcut.
            Button("Strike Out") {
                model?.addMarkup(.strikeOut)
            }
            .disabled(model?.canAddMarkup(.strikeOut) != true)

            Button("Add Note") {
                addNote?()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(model?.canCreateNote != true)

            Divider()

            Button("Convert Annotation") {
                model?.convertSelectedMarkup()
            }
            .disabled(model?.canModifySelectedMarkup != true)

            Button("Delete Annotation") {
                model?.deleteSelectedMarkup()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(model?.canModifySelectedMarkup != true)
        }

        CommandMenu("Page") {
            Button("Next Page") {
                model?.goToNextPage()
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(!(model.map { $0.isLoaded && $0.currentPageIndex < $0.pageCount - 1 } ?? false))

            Button("Previous Page") {
                model?.goToPreviousPage()
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(!(model.map { $0.isLoaded && $0.currentPageIndex > 0 } ?? false))
        }

        CommandGroup(after: .toolbar) {
            // ⌘B is the sidebar toggle used by coding editors and terminals.
            // Like the toolbar button it only applies once a PDF is loaded.
            Button("Toggle Sidebar") {
                sidebarActions?.toggle()
            }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(sidebarActions == nil || model?.isLoaded != true)

            Button("Outline") {
                sidebarActions?.select(.outline)
            }
            .disabled(sidebarActions == nil || model?.isLoaded != true)

            Button("Thumbnails") {
                sidebarActions?.select(.thumbnails)
            }
            .disabled(sidebarActions == nil || model?.isLoaded != true)

            Button("Annotations") {
                sidebarActions?.select(.annotations)
            }
            .disabled(sidebarActions == nil || model?.isLoaded != true)

            Divider()

            Button("Zoom In") {
                model?.zoomIn()
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(model?.isLoaded != true)

            Button("Zoom Out") {
                model?.zoomOut()
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(model?.isLoaded != true)

            Button("Actual Size") {
                model?.resetZoom()
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(model?.isLoaded != true)

            Button("Fit to Window") {
                model?.fitToWindow()
            }
            .keyboardShortcut("9", modifiers: .command)
            .disabled(model?.isLoaded != true)
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                updateController.checkForUpdates()
            }
            .disabled(!updateController.canCheckForUpdates)
        }
    }
}
