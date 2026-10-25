import SwiftUI
import YoPDFCore

@main
struct YoPDFApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var updateController = SparkleUpdateController.shared
    @StateObject private var recentDocuments = RecentDocumentsStore.shared

    var body: some Scene {
        WindowGroup {
            ReaderWindow(
                updateController: updateController,
                recentDocuments: recentDocuments,
                fileOpenRequests: appDelegate.fileOpenRequests
            )
        }
        .defaultSize(width: 1100, height: 820)
        // Leave document-open events to AppKit's application(_:open:) handler.
        // Without this, WindowGroup claims external file URLs by creating an
        // empty scene before the PDF reader can consume the request.
        .handlesExternalEvents(matching: [])
        .commands {
            PDFReaderCommands(
                updateController: updateController,
                recentDocuments: recentDocuments
            )
        }
    }
}

/// One window, one document.
///
/// `@StateObject` lives here rather than on `YoPDFApp` so every `WindowGroup`
/// scene gets its own `PDFDocumentModel`: two windows can show different PDFs,
/// closing one does not touch the other, and each model releases only its own
/// security-scoped access.
///
/// Finder's AppKit open-file callbacks enqueue URLs before or after this window
/// exists. `PDFReaderView` consumes them when this window is key and routes them
/// through its normal unsaved-work prompt.
private struct ReaderWindow: View {

    @ObservedObject var updateController: SparkleUpdateController
    @ObservedObject var recentDocuments: RecentDocumentsStore
    let fileOpenRequests: FileOpenRequestQueue
    @StateObject private var model: PDFDocumentModel

    init(
        updateController: SparkleUpdateController,
        recentDocuments: RecentDocumentsStore,
        fileOpenRequests: FileOpenRequestQueue
    ) {
        self.updateController = updateController
        self.recentDocuments = recentDocuments
        self.fileOpenRequests = fileOpenRequests
        _model = StateObject(wrappedValue: PDFDocumentModel(recentDocuments: recentDocuments))
    }

    var body: some View {
        PDFReaderView(
            model: model,
            updateController: updateController,
            recentDocuments: recentDocuments,
            fileOpenRequests: fileOpenRequests
        )
    }
}
