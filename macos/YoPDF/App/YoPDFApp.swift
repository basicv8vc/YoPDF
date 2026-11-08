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
            navigationState: tab.navigationState,
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
        // Recent-document previews are sensitive (first pages of the user's
        // files), so their cache must follow the list everywhere it changes.
        // The grid prunes while it is visible; this observer covers the cases
        // where the grid is gone — File → Open Recent → Clear Menu removes
        // the empty state together with the list, and an open document hides
        // it entirely. Clearing must not leave preview images on disk.
        .onChange(of: recentDocuments.items) { _, items in
            RecentDocumentThumbnailProvider.shared.prune(
                keeping: Set(items.map(\.id))
            )
        }
    }
}
