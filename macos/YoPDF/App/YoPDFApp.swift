import SwiftUI
import YoPDFCore

@main
struct YoPDFApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var updateController = SparkleUpdateController.shared
    @StateObject private var recentDocuments = RecentDocumentsStore.shared

    var body: some Scene {
        WindowGroup(id: "reader") {
            ReaderWindow(
                updateController: updateController,
                recentDocuments: recentDocuments,
                fileOpenRequests: appDelegate.fileOpenRequests
            )
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .defaultSize(width: 1100, height: 820)
        // A cold file-open event must be allowed to create a reader. Existing
        // readers prefer subsequent events, avoiding an extra empty window.
        .handlesExternalEvents(matching: ["*"])
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

    @Environment(\.openWindow) private var openWindow
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
        let openWindowAction = openWindow
        PDFReaderView(
            model: model,
            updateController: updateController,
            recentDocuments: recentDocuments,
            fileOpenRequests: fileOpenRequests
        )
        .onAppear {
            fileOpenRequests.registerReaderWindowOpener {
                openWindowAction(id: "reader")
            }
        }
    }
}
