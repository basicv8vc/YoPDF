import SwiftUI
import YoPDFCore

/// The 540×560 expanded note editor, matching ShuaMac's sheet composer.
struct NoteStickerSheetEditor: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var session: NoteComposerSession
    @ObservedObject var model: PDFDocumentModel
    let onSave: () -> String?

    @State private var initialDraft: NoteComposerSession.Snapshot
    @State private var errorMessage: String?

    init(
        session: NoteComposerSession,
        model: PDFDocumentModel,
        onSave: @escaping () -> String?
    ) {
        self.session = session
        self.model = model
        self.onSave = onSave
        _initialDraft = State(initialValue: session.snapshot())
    }

    private var title: String {
        if session.isEditing { return "Edit Note" }
        return session.isGroupComposer ? "New Thought" : "New Note"
    }

    private var isEmpty: Bool {
        session.contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let permissions = session.editorPermissions(in: model)
        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(.headline)

            NoteStickerComposer(
                text: $session.contents,
                style: $session.style,
                expanded: true,
                templateSelection: $session.templateSelection,
                canEditContents: permissions.canEditContents,
                canChangeStyle: permissions.canChangeStyle
            )

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.62, green: 0.16, blue: 0.12))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    session.restore(from: initialDraft)
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isEmpty)
            }
        }
        .padding(24)
        .frame(width: 540, height: 560)
    }

    private func save() {
        errorMessage = nil
        if let message = onSave() {
            errorMessage = message
            return
        }
        dismiss()
    }
}
