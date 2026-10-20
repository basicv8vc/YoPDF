import SwiftUI
import YoPDFCore

/// The focused window's document model, so menu commands act on the active
/// window instead of a shared app-level instance.
struct DocumentModelFocusKey: FocusedValueKey {
    typealias Value = PDFDocumentModel
}

/// Presents the open panel for the focused window. Kept as an action so the
/// command layer does not need to know which view owns the file importer.
struct OpenDocumentActionKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

extension FocusedValues {
    var documentModel: PDFDocumentModel? {
        get { self[DocumentModelFocusKey.self] }
        set { self[DocumentModelFocusKey.self] = newValue }
    }

    var openDocument: (@MainActor () -> Void)? {
        get { self[OpenDocumentActionKey.self] }
        set { self[OpenDocumentActionKey.self] = newValue }
    }
}
