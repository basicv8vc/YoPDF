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
        // Finder events are accepted by AppDelegate and delivered to the
        // frontmost available workspace window in FIFO order.
        .handlesExternalEvents(matching: ["*"])
        .commands {
            PDFReaderCommands(
                updateController: updateController,
                recentDocuments: recentDocuments
            )
        }
    }
}

/// One independent window, with stable PDF sessions owned by its workspace.
private struct ReaderWindow: View {

    @Environment(\.openWindow) private var openWindow
    @ObservedObject var updateController: SparkleUpdateController
    @ObservedObject var recentDocuments: RecentDocumentsStore
    let fileOpenRequests: FileOpenRequestQueue

    @StateObject private var workspace: WorkspaceWindowModel

    init(
        updateController: SparkleUpdateController,
        recentDocuments: RecentDocumentsStore,
        fileOpenRequests: FileOpenRequestQueue
    ) {
        self.updateController = updateController
        self.recentDocuments = recentDocuments
        self.fileOpenRequests = fileOpenRequests
        _workspace = StateObject(wrappedValue: WorkspaceWindowModel {
            PDFDocumentModel(recentDocuments: recentDocuments)
        })
    }

    var body: some View {
        let openWindowAction = openWindow
        let tab = workspace.activeTab
        PDFReaderView(
            workspace: workspace,
            model: tab.model,
            composerStore: tab.composerStore,
            searchSession: tab.searchSession,
            updateController: updateController,
            recentDocuments: recentDocuments,
            fileOpenRequests: fileOpenRequests,
            canReceiveFinderOpenRequest: true
        )
        .onAppear {
            fileOpenRequests.registerReaderWindowOpener {
                openWindowAction(id: "reader")
            }
        }
    }
}
