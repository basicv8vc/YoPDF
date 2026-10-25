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

/// Opens a saved recent URL through the focused reader's unsaved-work prompts.
struct OpenRecentDocumentActionKey: FocusedValueKey {
    typealias Value = @MainActor (RecentDocument) -> Void
}

/// Menu-bar counterparts of the toolbar's editing actions.
///
/// They are actions rather than model calls because the reader has to route them
/// through the same unsaved-changes and save-outcome handling as the buttons; a
/// menu item that called `model.save()` directly would skip it.
struct SaveDocumentActionKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

struct SaveDocumentAsActionKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

struct ExportAnnotationsActionKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

struct FindInDocumentActionKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

struct FindNextSearchResultActionKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

struct FindPreviousSearchResultActionKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

struct HighlightSelectionActionKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

struct UnderlineSelectionActionKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

/// Add Note needs the reader's state, not just the model: with no selection the
/// action switches the page into placement mode.
struct AddNoteActionKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

/// Sidebar controls are reader actions because each window owns its own
/// visibility and selected document view.
struct ReaderSidebarActionsFocusKey: FocusedValueKey {
    typealias Value = ReaderSidebarActions
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

    var openRecentDocument: (@MainActor (RecentDocument) -> Void)? {
        get { self[OpenRecentDocumentActionKey.self] }
        set { self[OpenRecentDocumentActionKey.self] = newValue }
    }

    var saveDocument: (@MainActor () -> Void)? {
        get { self[SaveDocumentActionKey.self] }
        set { self[SaveDocumentActionKey.self] = newValue }
    }

    var saveDocumentAs: (@MainActor () -> Void)? {
        get { self[SaveDocumentAsActionKey.self] }
        set { self[SaveDocumentAsActionKey.self] = newValue }
    }

    var exportAnnotations: (@MainActor () -> Void)? {
        get { self[ExportAnnotationsActionKey.self] }
        set { self[ExportAnnotationsActionKey.self] = newValue }
    }

    var findInDocument: (@MainActor () -> Void)? {
        get { self[FindInDocumentActionKey.self] }
        set { self[FindInDocumentActionKey.self] = newValue }
    }

    var findNextSearchResult: (@MainActor () -> Void)? {
        get { self[FindNextSearchResultActionKey.self] }
        set { self[FindNextSearchResultActionKey.self] = newValue }
    }

    var findPreviousSearchResult: (@MainActor () -> Void)? {
        get { self[FindPreviousSearchResultActionKey.self] }
        set { self[FindPreviousSearchResultActionKey.self] = newValue }
    }

    var highlightSelection: (@MainActor () -> Void)? {
        get { self[HighlightSelectionActionKey.self] }
        set { self[HighlightSelectionActionKey.self] = newValue }
    }

    var underlineSelection: (@MainActor () -> Void)? {
        get { self[UnderlineSelectionActionKey.self] }
        set { self[UnderlineSelectionActionKey.self] = newValue }
    }

    var addNote: (@MainActor () -> Void)? {
        get { self[AddNoteActionKey.self] }
        set { self[AddNoteActionKey.self] = newValue }
    }

    var readerSidebarActions: ReaderSidebarActions? {
        get { self[ReaderSidebarActionsFocusKey.self] }
        set { self[ReaderSidebarActionsFocusKey.self] = newValue }
    }
}
