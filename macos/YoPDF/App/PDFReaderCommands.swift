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
    @FocusedValue(\.activePaneKind) private var activePaneKind
    @FocusedValue(\.openDocument) private var openDocument
    @FocusedValue(\.newWorkspaceTab) private var newWorkspaceTab
    @FocusedValue(\.closeWorkspaceTab) private var closeWorkspaceTab
    @FocusedValue(\.selectPreviousWorkspaceTab) private var selectPreviousWorkspaceTab
    @FocusedValue(\.selectNextWorkspaceTab) private var selectNextWorkspaceTab
    @FocusedValue(\.workspaceTabMove) private var workspaceTabMove
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
    @FocusedValue(\.splitRight) private var splitRight
    @FocusedValue(\.splitDown) private var splitDown
    @FocusedValue(\.closePane) private var closePane
    @FocusedValue(\.activeUndo) private var activeUndo
    @FocusedValue(\.activeRedo) private var activeRedo
    @FocusedValue(\.openPaperNote) private var openPaperNote
    @FocusedValue(\.newMarkdownNote) private var newMarkdownNote
    @FocusedValue(\.insertCitation) private var insertCitation

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

            Button("Open…") {
                openDocument?()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(openDocument == nil)

            Button("New Markdown Note…") {
                newMarkdownNote?()
            }
            .keyboardShortcut("m", modifiers: [.command, .option])
            .disabled(newMarkdownNote == nil)

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

            Divider()

            // Keyboard-only counterpart of dragging a tab. Both directions wrap
            // at the ends, so holding a key keeps cycling instead of stalling at
            // an edge (see WorkspaceState.move(tabID:direction:)).
            Button("Move Tab Left") {
                workspaceTabMove?.move(.previous)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
            .disabled((workspaceTabMove?.tabCount ?? 0) < 2)

            Button("Move Tab Right") {
                workspaceTabMove?.move(.next)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
            .disabled((workspaceTabMove?.tabCount ?? 0) < 2)
        }

        // Annotation edits and Markdown edits are both routed through
        // `activeUndo` / `activeRedo` so an empty Markdown undo stack never
        // falls back to undoing edits on a companion PDF pane.
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                activeUndo?()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(activeUndo == nil)

            Button("Redo") {
                activeRedo?()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(activeRedo == nil)
        }

        // Replaces the standard Save/Save As items: those would call into AppKit
        // document machinery this app does not use, and would skip the
        // unsaved-changes and save-outcome handling the reader owns.
        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                saveDocument?()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(saveDocument == nil)

            Button("Save As…") {
                saveDocumentAs?()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(saveDocumentAs == nil)

            Divider()

            Button("Export Annotations as Markdown…") {
                exportAnnotations?()
            }
            .disabled(exportAnnotations == nil || model?.isLoaded != true)
        }

        CommandGroup(after: .pasteboard) {
            Button("Find…") {
                findInDocument?()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(findInDocument == nil)

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
            let isPDFPaneActive = (activePaneKind ?? .pdf) == .pdf

            Button("Highlight") {
                highlightSelection?()
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(!isPDFPaneActive || highlightSelection == nil || model?.canAddMarkup(.highlight) != true)

            Button("Underline") {
                underlineSelection?()
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(!isPDFPaneActive || underlineSelection == nil || model?.canAddMarkup(.underline) != true)

            // No key equivalent: ⇧⌘S is already Save As. Preview also leaves
            // Strike Out unshortcut.
            Button("Strike Out") {
                model?.addMarkup(.strikeOut)
            }
            .disabled(!isPDFPaneActive || model?.canAddMarkup(.strikeOut) != true)

            Button("Add Note") {
                addNote?()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!isPDFPaneActive || addNote == nil || model?.canCreateNote != true)

            Divider()

            Button("Convert Annotation") {
                model?.convertSelectedMarkup()
            }
            .disabled(!isPDFPaneActive || model?.canModifySelectedMarkup != true)

            Button("Delete Annotation") {
                model?.deleteSelectedMarkup()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!isPDFPaneActive || model?.canModifySelectedMarkup != true)
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

        CommandMenu("Layout") {
            Button("Open Paper Note") {
                openPaperNote?()
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(openPaperNote == nil)

            Button("Cite in Paper Note") {
                insertCitation?()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(insertCitation == nil)

            Divider()

            Button("Split Right") {
                splitRight?()
            }
            .keyboardShortcut("\\", modifiers: .command)
            .disabled(splitRight == nil)

            Button("Split Down") {
                splitDown?()
            }
            .keyboardShortcut("\\", modifiers: [.command, .shift])
            .disabled(splitDown == nil)

            Button("Close Pane") {
                closePane?()
            }
            .keyboardShortcut("w", modifiers: [.command, .option])
            .disabled(closePane == nil)
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                updateController.checkForUpdates()
            }
            // Not `canCheckForUpdates`: see `isUpdateCheckingAvailable`.
            .disabled(!updateController.isUpdateCheckingAvailable)
        }
    }
}
