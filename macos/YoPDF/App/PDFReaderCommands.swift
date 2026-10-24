import AppKit
import SwiftUI
import YoPDFCore

/// Menu-bar commands for the reader.
///
/// Every command reads the focused window's model, so with several windows open
/// `⌘+` or Page Down only affects the active one. Commands disable themselves
/// when no reader window is focused.
struct PDFReaderCommands: Commands {

    @ObservedObject private var updateController: SparkleUpdateController

    @FocusedValue(\.documentModel) private var model
    @FocusedValue(\.openDocument) private var openDocument
    @FocusedValue(\.saveDocument) private var saveDocument
    @FocusedValue(\.saveDocumentAs) private var saveDocumentAs
    @FocusedValue(\.highlightSelection) private var highlightSelection
    @FocusedValue(\.underlineSelection) private var underlineSelection
    @FocusedValue(\.addNote) private var addNote

    init(updateController: SparkleUpdateController) {
        self.updateController = updateController
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open PDF…") {
                openDocument?()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(openDocument == nil)

            // Replacing `.newItem` and `.saveItem` removes the standard Close
            // item, so it is added back. Closing goes through `performClose:`
            // and therefore through `WindowCloseGuard`, which is what keeps ⌘W
            // from dropping unsaved edits.
            Button("Close") {
                NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(model == nil)
        }

        // Annotation edits use the model's own history rather than PDFKit's
        // UndoManager. A cross-page mark is one entry, a recolour gesture is one
        // entry, and the history is cleared when a save reloads the document.
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
