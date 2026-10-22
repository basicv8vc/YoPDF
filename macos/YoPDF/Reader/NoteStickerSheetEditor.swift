import SwiftUI
import YoPDFCore

/// The 540×560 expanded note editor, matching ShuaMac's sheet composer.
struct NoteStickerSheetEditor: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let canEditContents: Bool
    let canChangeStyle: Bool
    let onCancel: () -> Void
    let onSave: () -> String?

    @Binding private var text: String
    @Binding private var style: NoteStickerStyle
    @Binding private var templateSelection: NoteTemplateSelection
    @State private var errorMessage: String?

    init(
        title: String,
        text: Binding<String>,
        style: Binding<NoteStickerStyle>,
        templateSelection: Binding<NoteTemplateSelection>,
        canEditContents: Bool,
        canChangeStyle: Bool,
        onCancel: @escaping () -> Void,
        onSave: @escaping () -> String?
    ) {
        self.title = title
        self.canEditContents = canEditContents
        self.canChangeStyle = canChangeStyle
        self.onCancel = onCancel
        self.onSave = onSave
        _text = text
        _style = style
        _templateSelection = templateSelection
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(.headline)

            NoteStickerComposer(
                text: $text,
                style: $style,
                expanded: true,
                templateSelection: $templateSelection,
                canEditContents: canEditContents,
                canChangeStyle: canChangeStyle
            )

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.62, green: 0.16, blue: 0.12))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedText.isEmpty)
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
