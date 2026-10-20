import SwiftUI
import YoPDFCore

/// Menu-bar commands for the reader.
///
/// Every command reads the focused window's model, so with several windows open
/// `⌘+` or Page Down only affects the active one. Commands disable themselves
/// when no reader window is focused.
struct PDFReaderCommands: Commands {

    @FocusedValue(\.documentModel) private var model
    @FocusedValue(\.openDocument) private var openDocument

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open PDF…") {
                openDocument?()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(openDocument == nil)
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
    }
}
