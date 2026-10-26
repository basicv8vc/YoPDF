import SwiftUI
import YoPDFCore

@main
struct YoPDFApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var updateController = SparkleUpdateController.shared
    @StateObject private var recentDocuments = RecentDocumentsStore.shared

    var body: some Scene {
        WindowGroup(id: "reader", for: UUID.self) { $readerWindowRequestID in
            ReaderWindow(
                readerWindowRequestID: $readerWindowRequestID,
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
/// exists. A reader with no PDF consumes the request itself; an already-loaded
/// reader opens it in a separate scene so both documents remain available.
private struct ReaderWindow: View {

    @Environment(\.openWindow) private var openWindow
    @Binding var readerWindowRequestID: UUID?
    @ObservedObject var updateController: SparkleUpdateController
    @ObservedObject var recentDocuments: RecentDocumentsStore
    let fileOpenRequests: FileOpenRequestQueue
    @StateObject private var model: PDFDocumentModel
    @State private var initialReaderWindowRequestDidResolve = false
    @State private var completedReaderWindowRequestID: UUID?

    private var canReceiveFinderOpenRequest: Bool {
        guard let readerWindowRequestID else {
            return initialReaderWindowRequestDidResolve
        }
        return completedReaderWindowRequestID == readerWindowRequestID
    }

    init(
        readerWindowRequestID: Binding<UUID?>,
        updateController: SparkleUpdateController,
        recentDocuments: RecentDocumentsStore,
        fileOpenRequests: FileOpenRequestQueue
    ) {
        _readerWindowRequestID = readerWindowRequestID
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
            fileOpenRequests: fileOpenRequests,
            canReceiveFinderOpenRequest: canReceiveFinderOpenRequest,
            openReaderWindow: { url, relinkingRecentDocumentID in
                let requestID = fileOpenRequests.enqueueReaderWindowRequest(
                    url: url,
                    relinkingRecentDocumentID: relinkingRecentDocumentID
                )
                openWindowAction(value: requestID)
            }
        )
        .task(id: readerWindowRequestID) {
            guard let readerWindowRequestID else {
                initialReaderWindowRequestDidResolve = true
                return
            }

            #if DEBUG
            // UI tests hold a newly created scene before consuming its UUID
            // request, exercising back-to-back Finder events deterministically.
            let delayArgument = "--yopdf-test-reader-request-delay-ms="
            let delay = ProcessInfo.processInfo.arguments.first(where: {
                $0.hasPrefix(delayArgument)
            }).flatMap { Int($0.dropFirst(delayArgument.count)) } ?? 0
            if delay > 0 {
                try? await Task.sleep(for: .milliseconds(delay))
            }
            #endif

            guard let request = fileOpenRequests.takeReaderWindowRequest(
                id: readerWindowRequestID
            ) else {
                completedReaderWindowRequestID = readerWindowRequestID
                return
            }

            let relinkingRecentDocument = request.relinkingRecentDocumentID.flatMap { id in
                recentDocuments.items.first(where: { $0.id == id })
            }
            if let relinkingRecentDocument {
                _ = model.open(url: request.url, relinking: relinkingRecentDocument)
            } else {
                _ = model.open(url: request.url)
            }
            completedReaderWindowRequestID = readerWindowRequestID
        }
        .onAppear {
            fileOpenRequests.registerReaderWindowOpener {
                openWindowAction(id: "reader")
            }
        }
        .onDisappear {
            guard let readerWindowRequestID else { return }
            fileOpenRequests.discardReaderWindowRequest(id: readerWindowRequestID)
        }
    }
}
