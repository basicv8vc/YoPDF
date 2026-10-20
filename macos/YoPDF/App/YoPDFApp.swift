import SwiftUI
import YoPDFCore

@main
struct YoPDFApp: App {

    @StateObject private var model = PDFDocumentModel()

    var body: some Scene {
        WindowGroup {
            PDFReaderView(model: model)
                .onOpenURL { url in
                    model.open(url: url)
                }
        }
        .defaultSize(width: 1100, height: 820)
        .commands {
            PDFReaderCommands(model: model)
        }
    }
}
