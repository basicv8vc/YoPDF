import SwiftUI
import YoPDFCore

/// Menu-bar commands for the reader. Zoom and page navigation are also
/// reachable from the toolbar; both routes go through `PDFDocumentModel`.
struct PDFReaderCommands: Commands {

    @ObservedObject var model: PDFDocumentModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open PDF…") {
                NotificationCenter.default.post(name: .yopdfRequestOpenDocument, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        CommandMenu("Page") {
            Button("Next Page") { model.goToNextPage() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!model.isLoaded || model.currentPageIndex >= model.pageCount - 1)

            Button("Previous Page") { model.goToPreviousPage() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!model.isLoaded || model.currentPageIndex == 0)
        }

        CommandGroup(after: .toolbar) {
            Button("Zoom In") { model.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!model.isLoaded)

            Button("Zoom Out") { model.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!model.isLoaded)

            Button("Actual Size") { model.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!model.isLoaded)

            Button("Fit to Window") { model.fitToWindow() }
                .keyboardShortcut("9", modifiers: .command)
                .disabled(!model.isLoaded)
        }
    }
}

extension Notification.Name {
    static let yopdfRequestOpenDocument = Notification.Name("dev.yopdf.requestOpenDocument")
}
