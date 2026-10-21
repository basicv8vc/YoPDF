import SwiftUI
import YoPDFCore

@main
struct YoPDFApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ReaderWindow()
        }
        .defaultSize(width: 1100, height: 820)
        .commands {
            PDFReaderCommands()
        }
    }
}

/// One window, one document.
///
/// `@StateObject` lives here rather than on `YoPDFApp` so every `WindowGroup`
/// scene gets its own `PDFDocumentModel`: two windows can show different PDFs,
/// closing one does not touch the other, and each model releases only its own
/// security-scoped access.
private struct ReaderWindow: View {

    @StateObject private var model = PDFDocumentModel()

    var body: some View {
        PDFReaderView(model: model)
            .onOpenURL { url in
                model.open(url: url)
            }
    }
}
