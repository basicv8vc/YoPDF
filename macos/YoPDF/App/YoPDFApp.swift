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
///
/// There is deliberately no `.onOpenURL` here. A URL that arrives from Finder
/// or a double-click is handled by `PDFReaderView`, which is the single place
/// that knows how to ask about unsaved edits first; a second handler at this
/// level would call `open` directly and race the prompt.
private struct ReaderWindow: View {

    @StateObject private var model = PDFDocumentModel()

    var body: some View {
        PDFReaderView(model: model)
    }
}
